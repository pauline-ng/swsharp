/*
swsharp - CUDA parallelized Smith Waterman with applying Hirschberg's and 
Ukkonen's algorithm and dynamic cell pruning.
Copyright (C) 2013 Matija Korpar, contributor Mile Šikić

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

Contact the author by mkorpar@gmail.com.
*/

#ifdef __CUDACC__

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "chain.h"
#include "constants.h"
#include "cpu_module.h"
#include "cuda_utils.h"
#include "error.h"
#include "scorer.h"
#include "sse_module.h"
#include "thread.h"
#include "threadpool.h"
#include "utils.h"

#include "score_database_gpu_short.h"

#define CPU_WORKER_STEP         32
#define CPU_THREADPOOL_STEP     100

#define THREADS   64
#define BLOCKS    120

#define INT4_ZERO make_int4(0, 0, 0, 0)
#define INT4_SCORE_MIN make_int4(SCORE_MIN, SCORE_MIN, SCORE_MIN, SCORE_MIN)

typedef void (*ScoringFunction)(int*, int2*, int*, int*, int*, int*, int, int);

typedef struct GpuSync {
    int last;
    Mutex mutex;
} GpuSync;

typedef struct CpuGpuSync {
    int lastGpu;
    int firstCpu;
    Mutex mutex;
} CpuGpuSync;

typedef struct GpuDatabase {
    int card;
    int* offsets;
    int* lengths;
    int* lengthsPadded;
    cudaArray* sequences;
    int* indexes;
    int* scores;
    int2* hBus;
} GpuDatabase;

typedef struct GpuDatabaseContext {
    int card;
    int length4;
    int blocks;
    int* offsets;
    size_t offsetsSize;
    int* lengths;
    int* lengthsPadded;
    size_t lengthsSize;
    char4* sequences;
    int sequencesCols;
    int sequencesRows;
    size_t sequencesSize;
    int* indexes;
    size_t indexesSize;
    GpuDatabase* gpuDatabase;
} GpuDatabaseContext;

struct ShortDatabase {
    Chain** database;
    int databaseLen;
    int length;
    int* positions;
    int* order;
    int* indexes;
    int blocks;
    int sequencesRows;
    int sequencesCols;
    GpuDatabase* gpuDatabases;
    int gpuDatabasesLen;
};

typedef struct Context {
    int* scores; 
    int type;
    Chain** queries;
    int queriesLen;
    ShortDatabase* shortDatabase;
    Scorer* scorer;
    int* indexes;
    int indexesLen;
    int* cards;
    int cardsLen;
    int useSimd;
} Context;

typedef struct QueryProfile {
    int height;
    int width;
    int length;
    char4* data;
    size_t size;
} QueryProfile;

typedef struct QueryProfileGpu {
    cudaArray* data;
} QueryProfileGpu;

typedef struct KernelContext {
    int* scores;
    ScoringFunction scoringFunction;
    ScoringFunction simdScoringFunction;
    QueryProfile* queryProfile;
    ShortDatabase* shortDatabase;
    Scorer* scorer;
    int* indexes;
    int indexesLen;
    int card;
    GpuSync* gpuSync;
    CpuGpuSync* cpuGpuSync;
} KernelContext;

typedef struct KernelContexts {
    int* scores;
    int type;
    ScoringFunction scoringFunction;
    ScoringFunction simdScoringFunction;
    Chain** queries;
    int queriesLen;
    ShortDatabase* shortDatabase;
    Scorer* scorer;
    int* indexes;
    int indexesLen;
    int card;
    GpuSync* gpuSync;
} KernelContexts;

typedef struct KernelContextCpu {
    int* scores;
    int type;
    Chain* query;
    ShortDatabase* shortDatabase;
    Scorer* scorer;
    int* indexes;
    int indexesLen;
    CpuGpuSync* cpuGpuSync;
    int useSimd;
} KernelContextCpu;

typedef struct CpuWorkerContext {
    int* scores;
    int type;
    Chain* query;
    Chain** database;
    int databaseLen;
    Scorer* scorer;
    CpuGpuSync* cpuGpuSync;
    int useSimd;
} CpuWorkerContext;

static __constant__ int gapOpen_;
static __constant__ int gapExtend_;

static __constant__ int rows_;
static __constant__ int rowsPadded_;
static __constant__ int width_;

texture<int, 2, cudaReadModeElementType> seqsTexture;
texture<char4, 2, cudaReadModeElementType> qpTexture;

//******************************************************************************
// PUBLIC

extern ShortDatabase* shortDatabaseCreate(Chain** database, int databaseLen, 
    int minLen, int maxLen, int* cards, int cardsLen);

extern void shortDatabaseDelete(ShortDatabase* shortDatabase);

extern void scoreShortDatabaseGpu(int* scores, int type, Chain* query, 
    ShortDatabase* shortDatabase, Scorer* scorer, int* indexes, int indexesLen, 
    int* cards, int cardsLen, Thread* thread);

extern void scoreShortDatabaseGpuChar(int* scores, int type, Chain* query, 
    ShortDatabase* shortDatabase, Scorer* scorer, int* indexes, int indexesLen, 
    int* cards, int cardsLen, Thread* thread);

extern void scoreShortDatabasesGpu(int* scores, int type, Chain** queries, 
    int queriesLen, ShortDatabase* shortDatabase, Scorer* scorer, int* indexes, 
    int indexesLen, int* cards, int cardsLen, Thread* thread);

extern void scoreShortDatabasesGpuChar(int* scores, int type, Chain** queries, 
    int queriesLen, ShortDatabase* shortDatabase, Scorer* scorer, int* indexes, 
    int indexesLen, int* cards, int cardsLen, Thread* thread);

//******************************************************************************

//******************************************************************************
// PRIVATE

// constructor
static ShortDatabase* createDatabase(Chain** database, int databaseLen, 
    int minLen, int maxLen, int* cards, int cardsLen);

// gpu constructor thread
static void* createDatabaseGpu(void* param);

// destructor
static void deleteDatabase(ShortDatabase* database);

// scoring 
static void scoreDatabase(int* scores, int type, Chain** queries, 
    int queriesLen, ShortDatabase* shortDatabase, Scorer* scorer, int* indexes, 
    int indexesLen, int* cards, int cardsLen, int useSimd, Thread* thread);

static void* scoreDatabaseThread(void* param);

static void scoreDatabaseMulti(int* scores, int type,
    ScoringFunction scoringFunction, ScoringFunction simdScoringFunction,
    Chain** queries, int queriesLen, ShortDatabase* shortDatabase, 
    Scorer* scorer, int* indexes, int indexesLen, int* cards, int cardsLen);

static void scoreDatabaseSingle(int* scores, int type,
    ScoringFunction scoringFunction, ScoringFunction simdScoringFunction,
    Chain** queries, int queriesLen, ShortDatabase* shortDatabase, 
    Scorer* scorer, int* indexes, int indexesLen, int* cards, int cardsLen);

// cpu kernels 
static void* kernelThread(void* param);

static void* kernelsThread(void* param);

static void* kernelThreadCpu(void* param);

static void* cpuWorker(void* param);

// gpu kernels 
__global__ static void hwSolveShortGpu(int* scores, int2* hBus, int* lengths, 
    int* lengthsPadded, int* offsets, int* indexes, int indexesLen, int block);
    
__global__ static void nwSolveShortGpu(int* scores, int2* hBus, int* lengths, 
    int* lengthsPadded, int* offsets, int* indexes, int indexesLen, int block);

__global__ static void ovSolveShortGpu(int* scores, int2* hBus, int* lengths, 
    int* lengthsPadded, int* offsets, int* indexes, int indexesLen, int block);

__global__ static void swSolveShortGpu(int* scores, int2* hBus, int* lengths, 
    int* lengthsPadded, int* offsets, int* indexes, int indexesLen, int block);

__global__ static void swSolveShortGpuSimd(int* scores, int2* hBus, 
    int* lengths, int* lengthsPadded, int* offsets, int* indexes,
    int indexesLen, int block);

// query profile
static QueryProfile* createQueryProfile(Chain* query, Scorer* scorer);

static void deleteQueryProfile(QueryProfile* queryProfile);

static QueryProfileGpu* createQueryProfileGpu(QueryProfile* queryProfile);

static void deleteQueryProfileGpu(QueryProfileGpu* queryProfileGpu);

// utils
static int int2CmpY(const void* a_, const void* b_);

//******************************************************************************

//******************************************************************************
// PUBLIC

//------------------------------------------------------------------------------
// CONSTRUCTOR, DESTRUCTOR

extern ShortDatabase* shortDatabaseCreate(Chain** database, int databaseLen, 
    int minLen, int maxLen, int* cards, int cardsLen) {
    return createDatabase(database, databaseLen, minLen, maxLen, cards, cardsLen);
}
    
extern void shortDatabaseDelete(ShortDatabase* shortDatabase) {
    deleteDatabase(shortDatabase);
}

extern size_t shortDatabaseGpuMemoryConsumption(Chain** database,
    int databaseLen, int minLen, int maxLen) {

    int length = 0;
    int maxHeight = 0;

    for (int i = 0; i < databaseLen; ++i) {

        const int n = chainGetLength(database[i]);
        
        if (n >= minLen && n < maxLen) {
            length++;
            maxHeight = max(maxHeight, n);
        }
    }

    if (length == 0) {
        return 0;
    }

    maxHeight = (maxHeight >> 2) + ((maxHeight & 3) > 0);

    int sequencesCols = THREADS * BLOCKS;

    int blocks = length / sequencesCols + (length % sequencesCols > 0);
    int hBusHeight = maxHeight * 4;

    //##########################################################################

    const int bucketDiff = 32;
    int bucketsLen = maxLen / bucketDiff + (maxLen % bucketDiff > 0);

    int* buckets = (int*) malloc(bucketsLen * sizeof(int));
    memset(buckets, 0, bucketsLen * sizeof(int));

    for (int i = 0; i < databaseLen; ++i) {

        const int n = chainGetLength(database[i]);
        
        if (n >= minLen && n < maxLen) {
            buckets[n >> 5]++;
        }
    }

    int sequencesRows = 0;
    for (int i = 0, j = 0; i < bucketsLen; ++i) {
        
        j += buckets[i];

        int d = j / sequencesCols;
        int r = j % sequencesCols;

        sequencesRows += d * ((i + 1) * (bucketDiff / 4));
        j = r;

        if (i == bucketsLen - 1 && j > 0) {
            sequencesRows += ((i + 1) * (bucketDiff / 4));
        }
    }

    free(buckets);

    //##########################################################################

    size_t hBusSize = sequencesCols * hBusHeight * sizeof(int2);
    size_t offsetsSize = blocks * sizeof(int);
    size_t lengthsSize = blocks * sequencesCols * sizeof(int);
    size_t sequencesSize = sequencesRows * sequencesCols * sizeof(char4);
    size_t scoresSize = length * sizeof(int);
    size_t indexesSize = length * sizeof(int);

    size_t memory = offsetsSize + 2 * lengthsSize + sequencesSize + 
        indexesSize + scoresSize + hBusSize;

    return memory;
}

//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// DATABASE SCORING

extern void scoreShortDatabaseGpu(int* scores, int type, Chain* query, 
    ShortDatabase* shortDatabase, Scorer* scorer, int* indexes, int indexesLen, 
    int* cards, int cardsLen, Thread* thread) {
    scoreDatabase(scores, type, &query, 1, shortDatabase, scorer, indexes, 
        indexesLen, cards, cardsLen, 0, thread);
}

extern void scoreShortDatabaseGpuChar(int* scores, int type, Chain* query, 
    ShortDatabase* shortDatabase, Scorer* scorer, int* indexes, int indexesLen, 
    int* cards, int cardsLen, Thread* thread) {
    scoreDatabase(scores, type, &query, 1, shortDatabase, scorer, indexes, 
        indexesLen, cards, cardsLen, 1, thread);
}

extern void scoreShortDatabasesGpu(int* scores, int type, Chain** queries, 
    int queriesLen, ShortDatabase* shortDatabase, Scorer* scorer, int* indexes, 
    int indexesLen, int* cards, int cardsLen, Thread* thread) {
    scoreDatabase(scores, type, queries, queriesLen, shortDatabase, scorer,
        indexes, indexesLen, cards, cardsLen, 0, thread);
}

extern void scoreShortDatabasesGpuChar(int* scores, int type, Chain** queries, 
    int queriesLen, ShortDatabase* shortDatabase, Scorer* scorer, int* indexes, 
    int indexesLen, int* cards, int cardsLen, Thread* thread) {
    scoreDatabase(scores, type, queries, queriesLen, shortDatabase, scorer,
        indexes, indexesLen, cards, cardsLen, 1, thread);
}

//------------------------------------------------------------------------------

//******************************************************************************

//******************************************************************************
// PRIVATE

//------------------------------------------------------------------------------
// CONSTRUCTOR, DESTRUCTOR 

static ShortDatabase* createDatabase(Chain** database, int databaseLen, 
    int minLen, int maxLen, int* cards, int cardsLen) {
    
    ASSERT(cardsLen > 0, "no GPUs available");

    //**************************************************************************
    // FILTER DATABASE AND REMEBER ORDER
    
    int length = 0;
    
    for (int i = 0; i < databaseLen; ++i) {
    
        const int n = chainGetLength(database[i]);
        
        if (n >= minLen && n < maxLen) {
            length++;
        }
    }
    
    if (length == 0) {
        return NULL;
    }

    int length4 = length + (4 - length % 4) % 4;
    
    int2* orderPacked = (int2*) malloc(length * sizeof(int2));

    for (int i = 0, j = 0; i < databaseLen; ++i) {
    
        const int n = chainGetLength(database[i]);
        
        if (n >= minLen && n < maxLen) {
            orderPacked[j].x = i;
            orderPacked[j].y = n;
            j++;
        }
    }
    
    qsort(orderPacked, length, sizeof(int2), int2CmpY);
    
    LOG("Short database length: %d", length);

    //**************************************************************************

    //**************************************************************************
    // CALCULATE GRID DIMENSIONS
    
    int sequencesCols = THREADS * BLOCKS;
    int sequencesRows = 0;

    int blocks = 0;
    for (int i = sequencesCols - 1; i < length; i += sequencesCols) {
        int n = chainGetLength(database[orderPacked[i].x]);
        sequencesRows += (n >> 2) + ((n & 3) > 0);
        blocks++;
    }
    
    if (length % sequencesCols != 0) {
        int n = chainGetLength(database[orderPacked[length - 1].x]);
        sequencesRows += (n >> 2) + ((n & 3) > 0);
        blocks++;
    }
    
    LOG("Short database grid: %d(%d)x%d", sequencesRows, blocks, sequencesCols);
    
    //**************************************************************************
    
    //**************************************************************************
    // INIT STRUCTURES
    
    size_t offsetsSize = blocks * sizeof(int);
    int* offsets = (int*) malloc(offsetsSize);
    
    size_t lengthsSize = blocks * sequencesCols * sizeof(int);
    int* lengths = (int*) malloc(lengthsSize);
    int* lengthsPadded = (int*) calloc(length4, sizeof(int)); // GPU-SIMD
    
    size_t sequencesSize = sequencesRows * sequencesCols * sizeof(char4);
    char4* sequences = (char4*) malloc(sequencesSize);
    memset(sequences, 127, sequencesSize);

    //***********f***************************************************************

    //**************************************************************************
    // CREATE GRID
    
    // tmp
    size_t sequenceSize = chainGetLength(database[orderPacked[length - 1].x]) + 4;
    char* sequence = (char*) malloc(sequenceSize);

    offsets[0] = 0;
    for(int i = 0, j = 0, cx = 0, cy = 0; i < length; i++){

        //get the sequence and its length
        Chain* chain = database[orderPacked[i].x];
        int n = chainGetLength(chain);    
        
        lengths[j * sequencesCols + cx] = n;
        
        chainCopyCodes(chain, sequence);
        memset(sequence + n, 127, 4 * sizeof(char));

        int n4 = (n >> 2) + ((n & 3) > 0);

        lengthsPadded[j * sequencesCols + cx] = n4;
        
        char4* ptr = sequences + cy * sequencesCols + cx;
        for(int k = 0; k < n; k += 4){
            ptr->x = sequence[k];
            ptr->y = sequence[k + 1];
            ptr->z = sequence[k + 2];
            ptr->w = sequence[k + 3];
            ptr += sequencesCols;
        }

        cx++;
        
        if(cx == sequencesCols){
            offsets[j + 1] = offsets[j] + n4;
            cx = 0;
            cy += n4;
            j++;
        }
    }
    
    free(sequence);
    
    //**************************************************************************
    
    //**************************************************************************
    // CREATE POSITION ARRAY
    
    int* positions = (int*) malloc(databaseLen * sizeof(int));

    for (int i = 0; i < databaseLen; ++i) {
        positions[i] = -1;
    }
    
    for (int i = 0; i < length; ++i) {
        positions[orderPacked[i].x] = i;
    }
    
    //**************************************************************************
    
    //**************************************************************************
    // CREATE ORDER ARRAY
    
    size_t orderSize = length * sizeof(int);
    int* order = (int*) malloc(orderSize);

    for (int i = 0; i < length; ++i) {
        order[i] = orderPacked[i].x;
    }
     
    //**************************************************************************
    
    //**************************************************************************
    // CREATE DEFAULT INDEXES
    
    // pad to length4 for GPU-SIMD usage
    size_t indexesSize = length4 * sizeof(int);
    int* indexes = (int*) malloc(indexesSize);

    for (int i = 0; i < length4; ++i) {
        indexes[i] = i;
    }

    //**************************************************************************

    //**************************************************************************
    // CREATE GPU DATABASES
    
    size_t gpuDatabasesSize = cardsLen * sizeof(GpuDatabase);
    GpuDatabase* gpuDatabases = (GpuDatabase*) malloc(gpuDatabasesSize);

    GpuDatabaseContext* contexts = 
        (GpuDatabaseContext*) malloc(cardsLen * sizeof(GpuDatabaseContext));

    Thread* threads = (Thread*) malloc(cardsLen * sizeof(Thread));

    for (int i = 0; i < cardsLen; ++i) {

        GpuDatabaseContext* context = &(contexts[i]);

        context->card = cards[i];
        context->length4 = length4;
        context->blocks = blocks;
        context->offsets = offsets;
        context->offsetsSize = offsetsSize;
        context->lengths = lengths;
        context->lengthsPadded = lengthsPadded;
        context->lengthsSize = lengthsSize;
        context->sequences = sequences;
        context->sequencesCols = sequencesCols;
        context->sequencesRows = sequencesRows;
        context->sequencesSize = sequencesSize;
        context->indexes = indexes;
        context->indexesSize = indexesSize;
        context->gpuDatabase = gpuDatabases + i;
    }

    for (int i = 1; i < cardsLen; ++i) {
        threadCreate(&(threads[i]), createDatabaseGpu, (void*) &(contexts[i]));
    }

    createDatabaseGpu((void*) &(contexts[0]));

    for (int i = 1; i < cardsLen; ++i) {
        threadJoin(threads[i]);
    }

    free(contexts);
    free(threads);

    //**************************************************************************
    
    //**************************************************************************
    // CLEAN MEMORY

    free(orderPacked);
    free(offsets);
    free(lengths);
    free(lengthsPadded);
    free(sequences);

    //**************************************************************************
    
    size_t shortDatabaseSize = sizeof(struct ShortDatabase);
    ShortDatabase* shortDatabase = (ShortDatabase*) malloc(shortDatabaseSize);
    
    shortDatabase->database = database;
    shortDatabase->databaseLen = databaseLen;
    shortDatabase->length = length;
    shortDatabase->positions = positions;
    shortDatabase->order = order;
    shortDatabase->indexes = indexes;
    shortDatabase->blocks = blocks;
    shortDatabase->sequencesRows = sequencesRows;
    shortDatabase->sequencesCols = sequencesCols;
    shortDatabase->gpuDatabases = gpuDatabases;
    shortDatabase->gpuDatabasesLen = cardsLen;
    
    return shortDatabase;
}

static void* createDatabaseGpu(void* param) {

    GpuDatabaseContext* context = (GpuDatabaseContext*) param;

    int card = context->card;
    int length4 = context->length4;
    int blocks = context->blocks;
    int* offsets = context->offsets;
    size_t offsetsSize = context->offsetsSize;
    int* lengths = context->lengths;
    int* lengthsPadded = context->lengthsPadded;
    size_t lengthsSize = context->lengthsSize;
    char4* sequences = context->sequences;
    int sequencesCols = context->sequencesCols;
    int sequencesRows = context->sequencesRows;
    size_t sequencesSize = context->sequencesSize;
    int* indexes = context->indexes;
    size_t indexesSize = context->indexesSize;
    GpuDatabase* gpuDatabase = context->gpuDatabase;

    CUDA_SAFE_CALL(cudaSetDevice(card));

    int* offsetsGpu;
    CUDA_SAFE_CALL(cudaMalloc(&offsetsGpu, offsetsSize));
    CUDA_SAFE_CALL(cudaMemcpy(offsetsGpu, offsets, offsetsSize, TO_GPU));
    
    int* lengthsGpu;
    CUDA_SAFE_CALL(cudaMalloc(&lengthsGpu, lengthsSize));
    CUDA_SAFE_CALL(cudaMemcpy(lengthsGpu, lengths, lengthsSize, TO_GPU));

    int* lengthsPaddedGpu;
    CUDA_SAFE_CALL(cudaMalloc(&lengthsPaddedGpu, lengthsSize));
    CUDA_SAFE_CALL(cudaMemcpy(lengthsPaddedGpu, lengthsPadded, lengthsSize, TO_GPU));
    
    cudaArray* sequencesGpu;
    cudaChannelFormatDesc channel = seqsTexture.channelDesc;
    CUDA_SAFE_CALL(cudaMallocArray(&sequencesGpu, &channel, sequencesCols, sequencesRows)); 
    CUDA_SAFE_CALL(cudaMemcpyToArray(sequencesGpu, 0, 0, sequences, sequencesSize, TO_GPU));
    CUDA_SAFE_CALL(cudaBindTextureToArray(seqsTexture, sequencesGpu));

    int* indexesGpu;
    CUDA_SAFE_CALL(cudaMalloc(&indexesGpu, indexesSize));
    CUDA_SAFE_CALL(cudaMemcpy(indexesGpu, indexes, indexesSize, TO_GPU));
    
    // additional structures

    // pad for SIMD
    size_t scoresSize = length4 * sizeof(int);
    int* scoresGpu;
    CUDA_SAFE_CALL(cudaMalloc(&scoresGpu, scoresSize));

    int2* hBusGpu;
    int hBusHeight = (sequencesRows - offsets[blocks - 1]) * 4;
    size_t hBusSize = sequencesCols * hBusHeight * sizeof(int2);
    CUDA_SAFE_CALL(cudaMalloc(&hBusGpu, hBusSize));

    gpuDatabase->card = card;
    gpuDatabase->offsets = offsetsGpu;
    gpuDatabase->lengths = lengthsGpu;
    gpuDatabase->lengthsPadded = lengthsPaddedGpu;
    gpuDatabase->sequences = sequencesGpu;
    gpuDatabase->indexes = indexesGpu;
    gpuDatabase->scores = scoresGpu;
    gpuDatabase->hBus = hBusGpu;
    
#ifdef DEBUG
    size_t memory = offsetsSize + 2 * lengthsSize + sequencesSize + 
        indexesSize + scoresSize + hBusSize;

    LOG("Short database using %.2lfMBs on card %d", memory / 1024.0 / 1024.0, card);
#endif

    return NULL;
}

static void deleteDatabase(ShortDatabase* database) {

    if (database == NULL) {
        return;
    }
    
    for (int i = 0; i < database->gpuDatabasesLen; ++i) {
    
        GpuDatabase* gpuDatabase = &(database->gpuDatabases[i]);
        
        CUDA_SAFE_CALL(cudaSetDevice(gpuDatabase->card));

        CUDA_SAFE_CALL(cudaFree(gpuDatabase->offsets));
        CUDA_SAFE_CALL(cudaFree(gpuDatabase->lengths));
        CUDA_SAFE_CALL(cudaFree(gpuDatabase->lengthsPadded));
        CUDA_SAFE_CALL(cudaFreeArray(gpuDatabase->sequences));
        CUDA_SAFE_CALL(cudaFree(gpuDatabase->indexes));
        CUDA_SAFE_CALL(cudaFree(gpuDatabase->scores));
        CUDA_SAFE_CALL(cudaFree(gpuDatabase->hBus));

        CUDA_SAFE_CALL(cudaUnbindTexture(seqsTexture));
    }

    free(database->gpuDatabases);
    free(database->positions);
    free(database->order);
    free(database->indexes);

    free(database);
}

//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// ENTRY 

static void scoreDatabase(int* scores, int type, Chain** queries, 
    int queriesLen, ShortDatabase* shortDatabase, Scorer* scorer, int* indexes, 
    int indexesLen, int* cards, int cardsLen, int useSimd, Thread* thread) {
    
    ASSERT(cardsLen > 0, "no GPUs available");
    
    Context* param = (Context*) malloc(sizeof(Context));
    
    param->scores = scores;
    param->type = type;
    param->queries = queries;
    param->queriesLen = queriesLen;
    param->shortDatabase = shortDatabase;
    param->scorer = scorer;
    param->indexes = indexes;
    param->indexesLen = indexesLen;
    param->cards = cards;
    param->cardsLen = cardsLen;
    param->useSimd = useSimd;

    if (thread == NULL) {
        scoreDatabaseThread(param);
    } else {
        threadCreate(thread, scoreDatabaseThread, (void*) param);
    }
}

//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// DATABASE SCORING

static void* scoreDatabaseThread(void* param) {

    Context* context = (Context*) param;
    
    int* scores = context->scores;
    int type = context->type;
    Chain** queries = context->queries;
    int queriesLen = context->queriesLen;
    ShortDatabase* shortDatabase = context->shortDatabase;
    Scorer* scorer = context->scorer;
    int* indexes = context->indexes;
    int indexesLen = context->indexesLen;
    int* cards = context->cards;
    int cardsLen = context->cardsLen;
    int useSimd = context->useSimd;

    if (shortDatabase == NULL) {
        return NULL;
    }

    //**************************************************************************
    // CREATE NEW INDEXES ARRAY IF NEEDED
    
    int* newIndexes = NULL;
    int newIndexesLen = 0;

    int deleteIndexes;

    if (indexes != NULL) {

        // translate and filter indexes, also make sure that indexes are 
        // sorted by size 
    
        int length = shortDatabase->length;
        int databaseLen = shortDatabase->databaseLen;
        int* positions = shortDatabase->positions;
        
        char* solveMask = (char*) malloc(length * sizeof(char));
        memset(solveMask, 0, length);
        
        newIndexesLen = 0;
        for (int i = 0; i < indexesLen; ++i) {
            
            int idx = indexes[i];
            if (idx < 0 || idx > databaseLen || positions[idx] == -1) {
                continue;
            }
            
            solveMask[positions[idx]] = 1;
            newIndexesLen++;
        }
        
        int newIndexesLen4 = newIndexesLen + (4 - newIndexesLen % 4) % 4;
        newIndexes = (int*) malloc(newIndexesLen4 * sizeof(int));
        
        for (int i = 0, j = 0; i < length; ++i) {
            if (solveMask[i]) {
                newIndexes[j++] = i;
            }
        }

        // pad for GPU-SIMD usage
        for (int i = newIndexesLen, j = 0; i < newIndexesLen4; ++i, ++j) {
            newIndexes[i] = length + j; 
        }
        
        free(solveMask);

        deleteIndexes = 1;

    } else {
        // load prebuilt defaults
        newIndexes = shortDatabase->indexes;
        newIndexesLen = shortDatabase->length;
        deleteIndexes = 0;
    }
    
    //**************************************************************************

    //**************************************************************************
    // CHOOSE SOLVING FUNCTION
    
    ScoringFunction function;
    ScoringFunction simdFunction;

    switch (type) {
    case SW_ALIGN: 
        function = swSolveShortGpu;
        simdFunction = useSimd ? swSolveShortGpuSimd : NULL;
        break;
    case NW_ALIGN: 
        function = nwSolveShortGpu;
        simdFunction = NULL;
        break;
    case HW_ALIGN:
        function = hwSolveShortGpu;
        simdFunction = NULL;
        break;
    case OV_ALIGN:
        function = ovSolveShortGpu;
        simdFunction = NULL;
        break;
    default:
        ERROR("Wrong align type");
    }

    WARNING(useSimd && swSolveShortGpuSimd == NULL, "not using GPU-SIMD solving");
    
    //**************************************************************************

    //**************************************************************************
    // SCORE MULTITHREADED

    if (queriesLen <= cardsLen) {
        scoreDatabaseMulti(scores, type, function, simdFunction, queries, 
            queriesLen, shortDatabase, scorer, newIndexes, newIndexesLen,
            cards, cardsLen);
    } else {
        scoreDatabaseSingle(scores, type, function, simdFunction, queries, 
            queriesLen, shortDatabase, scorer, newIndexes, newIndexesLen,
            cards, cardsLen);
    }
    
    //**************************************************************************

    //**************************************************************************
    // CLEAN MEMORY

    if (deleteIndexes) {
        free(newIndexes);
    }

    free(param);
    
    //**************************************************************************
    
    return NULL;
}

static void scoreDatabaseMulti(int* scores, int type,
    ScoringFunction scoringFunction, ScoringFunction simdScoringFunction,
    Chain** queries, int queriesLen, ShortDatabase* shortDatabase, 
    Scorer* scorer, int* indexes, int indexesLen, int* cards_, int cardsLen) {
    
    int databaseLen = shortDatabase->databaseLen;

    //**************************************************************************
    // DIVIDE CARDS

    int** cards = (int**) malloc(cardsLen * sizeof(int*));
    int* cardsLens = (int*) malloc(cardsLen * sizeof(int));

    int cardsChunk = cardsLen / queriesLen;
    int cardsAdd = cardsLen % queriesLen;

    for (int i = 0, cardsOff = 0; i < queriesLen; ++i) {
        cards[i] = cards_ + cardsOff;
        cardsLens[i] = cardsChunk + (i < cardsAdd);
        cardsOff += cardsLens[i];
    }

    //**************************************************************************

    //**************************************************************************
    // CREATE QUERY PROFILES AND SYNC DATA
    
    QueryProfile** profiles = (QueryProfile**) malloc(queriesLen * sizeof(QueryProfile*));

    GpuSync* gpuSyncs = (GpuSync*) malloc(queriesLen * sizeof(GpuSync));
    CpuGpuSync* cpuGpuSyncs = (CpuGpuSync*) malloc(queriesLen * sizeof(CpuGpuSync));

    for (int i = 0; i < queriesLen; ++i) {

        profiles[i] = createQueryProfile(queries[i], scorer);

        mutexCreate(&(gpuSyncs[i].mutex));
        gpuSyncs[i].last = 0;

        mutexCreate(&(cpuGpuSyncs[i].mutex));
        cpuGpuSyncs[i].lastGpu = 0;
        cpuGpuSyncs[i].firstCpu = INT_MAX;
    }
    
    //**************************************************************************
    
    //**************************************************************************
    // PREPARE CPU

    size_t cpuContextsSize = queriesLen * sizeof(KernelContextCpu);
    KernelContextCpu* contextsCpu = (KernelContextCpu*) malloc(cpuContextsSize);

    Thread* tasksCpu = (Thread*) malloc(queriesLen * sizeof(Thread));

    for (int i = 0; i < queriesLen; ++i) {

        contextsCpu[i].scores = scores + i * databaseLen;
        contextsCpu[i].type = type;
        contextsCpu[i].query = queries[i];
        contextsCpu[i].shortDatabase = shortDatabase;
        contextsCpu[i].scorer = scorer;
        contextsCpu[i].indexes = indexes;
        contextsCpu[i].indexesLen = indexesLen;
        contextsCpu[i].cpuGpuSync = &(cpuGpuSyncs[i]);
        contextsCpu[i].useSimd = simdScoringFunction != NULL;

        threadCreate(&(tasksCpu[i]), kernelThreadCpu, &(contextsCpu[i]));
    }

    //**************************************************************************

    //**************************************************************************
    // SCORE MULTICARDED
    
    KernelContext* contextsGpu = (KernelContext*) malloc(cardsLen * sizeof(KernelContext));
    Thread* tasksGpu = (Thread*) malloc(cardsLen * sizeof(Thread));

    for (int i = 0, k = 0; i < queriesLen; ++i) {
        for (int j = 0; j < cardsLens[i]; ++j, ++k) {
        
            contextsGpu[k].scores = scores + i * databaseLen;
            contextsGpu[k].scoringFunction = scoringFunction;
            contextsGpu[k].simdScoringFunction = simdScoringFunction;
            contextsGpu[k].queryProfile = profiles[i];
            contextsGpu[k].shortDatabase = shortDatabase;
            contextsGpu[k].scorer = scorer;
            contextsGpu[k].indexes = indexes;
            contextsGpu[k].indexesLen = indexesLen;
            contextsGpu[k].card = cards[i][j];
            contextsGpu[k].gpuSync = &(gpuSyncs[i]);
            contextsGpu[k].cpuGpuSync = &(cpuGpuSyncs[i]);

            threadCreate(&(tasksGpu[k]), kernelThread, &(contextsGpu[k]));
        }
    }
    
    for (int i = 0; i < cardsLen; ++i) {
        threadJoin(tasksGpu[i]);
    }

    //**************************************************************************
    
    //**************************************************************************
    // WAIT FOR CPU

    for (int i = 0; i < queriesLen; ++i) {
        threadJoin(tasksCpu[i]);
    }

    //**************************************************************************

    //**************************************************************************
    // CLEAN MEMORY

    for (int i = 0; i < queriesLen; ++i) {
        deleteQueryProfile(profiles[i]);
        mutexDelete(&(gpuSyncs[i].mutex));
        mutexDelete(&(cpuGpuSyncs[i].mutex));
    }

    free(tasksGpu);
    free(tasksCpu);
    free(contextsGpu);
    free(contextsCpu);
    free(profiles);
    free(gpuSyncs);
    free(cpuGpuSyncs);

    //**************************************************************************
}

static void scoreDatabaseSingle(int* scores, int type,
    ScoringFunction scoringFunction, ScoringFunction simdScoringFunction,
    Chain** queries, int queriesLen, ShortDatabase* shortDatabase, 
    Scorer* scorer, int* indexes, int indexesLen, int* cards, int cardsLen) {

    //**************************************************************************
    // SCORE MULTITHREADED
    
    size_t contextsSize = cardsLen * sizeof(KernelContexts);
    KernelContexts* contexts = (KernelContexts*) malloc(contextsSize);
    
    Thread* tasks = (Thread*) malloc(cardsLen * sizeof(Thread));

    GpuSync gpuSync;
    gpuSync.last = 0;
    mutexCreate(&(gpuSync.mutex));

    for (int i = 0; i < cardsLen; ++i) {

        contexts[i].scores = scores;
        contexts[i].type = type;
        contexts[i].scoringFunction = scoringFunction;
        contexts[i].simdScoringFunction = simdScoringFunction;
        contexts[i].queries = queries;
        contexts[i].queriesLen = queriesLen;
        contexts[i].shortDatabase = shortDatabase;
        contexts[i].scorer = scorer;
        contexts[i].indexes = indexes;
        contexts[i].indexesLen = indexesLen;
        contexts[i].card = cards[i];
        contexts[i].gpuSync = &gpuSync;

        threadCreate(&(tasks[i]), kernelsThread, &(contexts[i]));
    }

    for (int i = 0; i < cardsLen; ++i) {
        threadJoin(tasks[i]);
    }

    //**************************************************************************
    
    //**************************************************************************
    // CLEAN MEMORY

    mutexDelete(&(gpuSync.mutex));
    free(contexts);
    free(tasks);

    //**************************************************************************
}

//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// CPU KERNELS

static void* kernelsThread(void* param) {

    KernelContexts* context = (KernelContexts*) param;

    int* scores_ = context->scores;
    int type = context->type;
    ScoringFunction scoringFunction = context->scoringFunction;
    ScoringFunction simdScoringFunction = context->simdScoringFunction;
    Chain** queries = context->queries;
    int queriesLen = context->queriesLen;
    ShortDatabase* shortDatabase = context->shortDatabase;
    Scorer* scorer = context->scorer;
    int* indexes = context->indexes;
    int indexesLen = context->indexesLen;
    int card = context->card;
    GpuSync* gpuSync = context->gpuSync;

    int databaseLen = shortDatabase->databaseLen;

    int useGpuSimd = simdScoringFunction != NULL;

    //**************************************************************************
    // INIT STRUCTURES

    CpuGpuSync cpuGpuSync;
    mutexCreate(&(cpuGpuSync.mutex));

    KernelContext gpuContext;
    gpuContext.scoringFunction = scoringFunction;
    gpuContext.simdScoringFunction = simdScoringFunction;
    gpuContext.shortDatabase = shortDatabase;
    gpuContext.scorer = scorer;
    gpuContext.card = card;
    gpuContext.gpuSync = NULL;
    gpuContext.cpuGpuSync = &cpuGpuSync;
    gpuContext.indexes = indexes;
    gpuContext.indexesLen = indexesLen;

    KernelContextCpu cpuContext;
    cpuContext.type = type;
    cpuContext.shortDatabase = shortDatabase;
    cpuContext.scorer = scorer;
    cpuContext.cpuGpuSync = &cpuGpuSync;
    cpuContext.useSimd = simdScoringFunction != NULL;
    cpuContext.indexes = indexes;
    cpuContext.indexesLen = indexesLen;

    int* overflows = useGpuSimd ? (int*) malloc(indexesLen * sizeof(int)) : NULL;

    //**************************************************************************

    //**************************************************************************
    // SOLVE

    Thread thread;

    while (1) {

        mutexLock(&(gpuSync->mutex));

        int queryIdx = gpuSync->last;
        gpuSync->last++;
    
        mutexUnlock(&(gpuSync->mutex));

        if (queryIdx >= queriesLen) {
            break;
        }

        Chain* query = queries[queryIdx];
        int* scores = scores_ + queryIdx * databaseLen;

        // reset sync
        cpuGpuSync.lastGpu = 0;
        cpuGpuSync.firstCpu = INT_MAX;

        // init specifix cpu and run
        cpuContext.scores = scores;
        cpuContext.query = query;

        threadCreate(&thread, kernelThreadCpu, &cpuContext);

        // init specifix gpu and run
        gpuContext.scores = scores;
        gpuContext.queryProfile = createQueryProfile(query, scorer);

        kernelThread(&gpuContext);

        // wait for cpu
        threadJoin(thread);

        // clean memory
        deleteQueryProfile(gpuContext.queryProfile);
    }

    //**************************************************************************

    //**************************************************************************
    // CLEAN MEMORY

    mutexDelete(&(cpuGpuSync.mutex));
    free(overflows);

    //**************************************************************************

    return NULL;
}

static void* kernelThread(void* param) {

    KernelContext* context = (KernelContext*) param;
    
    int* scores = context->scores;
    ScoringFunction scoringFunction = context->scoringFunction;
    ScoringFunction simdScoringFunction = context->simdScoringFunction;
    QueryProfile* queryProfile = context->queryProfile;
    ShortDatabase* shortDatabase = context->shortDatabase;
    Scorer* scorer = context->scorer;
    int* indexes = context->indexes;
    int indexesLen = context->indexesLen;
    int card = context->card;
    GpuSync* gpuSync = context->gpuSync;
    CpuGpuSync* cpuGpuSync = context->cpuGpuSync;

    //**************************************************************************
    // FIND DATABASE
    
    GpuDatabase* gpuDatabases = shortDatabase->gpuDatabases;
    int gpuDatabasesLen = shortDatabase->gpuDatabasesLen;
    
    GpuDatabase* gpuDatabase = NULL;
    
    for (int i = 0; i < gpuDatabasesLen; ++i) {
        if (gpuDatabases[i].card == card) {
            gpuDatabase = &(gpuDatabases[i]);
            break;
        }
    }

    ASSERT(gpuDatabase != NULL, "Short database not available on card %d", card);

    //**************************************************************************
    
    //**************************************************************************
    // CUDA SETUP
    
    int currentCard;
    CUDA_SAFE_CALL(cudaGetDevice(&currentCard));
    if (currentCard != card) {
        CUDA_SAFE_CALL(cudaSetDevice(card));
    }
    
    //**************************************************************************
    
    //**************************************************************************
    // FIX INDEXES
    
    int deleteIndexes;
    int* indexesGpu;
    
    if (indexesLen == shortDatabase->length) {
        indexes = shortDatabase->indexes;
        indexesLen = shortDatabase->length;
        indexesGpu = gpuDatabase->indexes;
        deleteIndexes = 0;
    } else {

        // align to 4 in case of GPU SIMD 
        int indexesLen4 = indexesLen + (4 - indexesLen % 4) % 4;
        size_t indexesSize = indexesLen4 * sizeof(int);

        CUDA_SAFE_CALL(cudaMalloc(&indexesGpu, indexesSize));
        CUDA_SAFE_CALL(cudaMemcpy(indexesGpu, indexes, indexesSize, TO_GPU));
        deleteIndexes = 1;
    }

    //**************************************************************************
    
    //**************************************************************************
    // PREPARE GPU
    
    QueryProfileGpu* queryProfileGpu = createQueryProfileGpu(queryProfile);
    
    int gapOpen = scorerGetGapOpen(scorer);
    int gapExtend = scorerGetGapExtend(scorer);
    int rows = queryProfile->length;
    int rowsGpu = queryProfile->height * 4;
    int sequencesCols = shortDatabase->sequencesCols;
    
    CUDA_SAFE_CALL(cudaMemcpyToSymbol(gapOpen_, &gapOpen, sizeof(int)));
    CUDA_SAFE_CALL(cudaMemcpyToSymbol(gapExtend_, &gapExtend, sizeof(int)));
    CUDA_SAFE_CALL(cudaMemcpyToSymbol(rows_, &rows, sizeof(int)));
    CUDA_SAFE_CALL(cudaMemcpyToSymbol(rowsPadded_, &rowsGpu, sizeof(int)));
    CUDA_SAFE_CALL(cudaMemcpyToSymbol(width_, &sequencesCols, sizeof(int)));
    
    //**************************************************************************

    //**************************************************************************
    // SOLVE

    bool useGpuSimd = simdScoringFunction != NULL;

    TIMER_START("Short GPU solving: %d, simd: %d", indexesLen, useGpuSimd);

    int blocks = shortDatabase->blocks;
    
    int* offsetsGpu = gpuDatabase->offsets;
    int* lengthsGpu = gpuDatabase->lengths;
    int* lengthsPaddedGpu = gpuDatabase->lengthsPadded;
    int* scoresGpu = gpuDatabase->scores;
    int2* hBusGpu = gpuDatabase->hBus;
    
    int blocksStep = useGpuSimd ? 4 : 1;
    int blocksLast = 0;
    int* blocksSolved = (int*) calloc(blocks, sizeof(int));

    int indexesLenLocal = 0;

    while (1) {

        int block;
        if (gpuSync == NULL) {

            // no need to sync
            block = blocksLast;
            blocksLast += blocksStep;

        } else {

            mutexLock(&(gpuSync->mutex));

            block = gpuSync->last;
            gpuSync->last += blocksStep;
        
            mutexUnlock(&(gpuSync->mutex));
        }

        if (sequencesCols * block > indexesLen) {
            break;
        }

        // wait for iteration to finish
        CUDA_SAFE_CALL(cudaDeviceSynchronize());

        int firstIdx = sequencesCols * block;
        int lastIdx = min(sequencesCols * (block + blocksStep), indexesLen);

        // multithreaded, check mutexes
        mutexLock(&(cpuGpuSync->mutex));

        // indexes already solved
        if (firstIdx >= cpuGpuSync->firstCpu) {
            mutexUnlock(&(cpuGpuSync->mutex));
            break;
        }

        indexesLenLocal = min(lastIdx, cpuGpuSync->firstCpu);
        cpuGpuSync->lastGpu = indexesLenLocal;

        mutexUnlock(&(cpuGpuSync->mutex));

        if (useGpuSimd) {
            simdScoringFunction<<<BLOCKS, THREADS>>>(scoresGpu, hBusGpu, 
                lengthsGpu, lengthsPaddedGpu, offsetsGpu, indexesGpu,
                indexesLenLocal, block);
        } else {
            scoringFunction<<<BLOCKS, THREADS>>>(scoresGpu, hBusGpu, 
                lengthsGpu, lengthsPaddedGpu, offsetsGpu, indexesGpu,
                indexesLenLocal, block);
        }

        blocksSolved[block] = 1;
    }

    CUDA_SAFE_CALL(cudaDeviceSynchronize());

    TIMER_STOP;

    //**************************************************************************
    
    //**************************************************************************
    // SAVE RESULTS

    int length = shortDatabase->length;
    int* order = shortDatabase->order;

    size_t scoresSize = length * sizeof(int);
    int* scoresCpu = (int*) malloc(scoresSize);
    CUDA_SAFE_CALL(cudaMemcpy(scoresCpu, scoresGpu, scoresSize, FROM_GPU));

    for (int i = 0; i < blocks; i += blocksStep) {

        if (!blocksSolved[i]) {
            continue;
        }

        int firstIdx = sequencesCols * i;
        int lastIdx = min(sequencesCols * (i + blocksStep), indexesLenLocal);

        for (int j = firstIdx; j < lastIdx; ++j) {
            scores[order[indexes[j]]] = scoresCpu[indexes[j]];
        }
    }

    //**************************************************************************

    //**************************************************************************
    // CLEAN MEMORY
    
    deleteQueryProfileGpu(queryProfileGpu);
    
    if (deleteIndexes) {
        CUDA_SAFE_CALL(cudaFree(indexesGpu));
    }

    free(blocksSolved);
    free(scoresCpu);

    //**************************************************************************
    
    return NULL;
}

static void* kernelThreadCpu(void* param) {

    KernelContextCpu* context = (KernelContextCpu*) param;

    int* scores = context->scores;
    int type = context->type;
    Chain* query = context->query;
    ShortDatabase* shortDatabase = context->shortDatabase;
    Scorer* scorer = context->scorer;
    int* indexes = context->indexes;
    int indexesLen = context->indexesLen;
    CpuGpuSync* cpuGpuSync = context->cpuGpuSync;
    int useSimd = context->useSimd;

    int* order = shortDatabase->order;

    if (indexesLen == 0) {
        return NULL;
    }

    //**************************************************************************
    // CREATE DATABASE
    
    int databaseLen = indexesLen;
    Chain** database = (Chain**) malloc(indexesLen * sizeof(Chain*));

    for (int i = 0; i < indexesLen; ++i) {
        database[i] = shortDatabase->database[order[indexes[i]]];
    }

    //**************************************************************************

    TIMER_START("Short CPU solving %d", databaseLen);

    //**************************************************************************
    // SOLVE

    int* scoresCpu = (int*) malloc(databaseLen * sizeof(int));

    CpuWorkerContext workerContext;
    workerContext.scores = scoresCpu;
    workerContext.type = type;
    workerContext.query = query;
    workerContext.database = database;
    workerContext.databaseLen = databaseLen;
    workerContext.scorer = scorer;
    workerContext.cpuGpuSync = cpuGpuSync;
    workerContext.useSimd = useSimd;

    int tasksNmr = CPU_THREADPOOL_STEP;
    ThreadPoolTask** tasks = (ThreadPoolTask**) malloc(tasksNmr * sizeof(ThreadPoolTask*));

    int over = 0;
    while (!over) {

        for (int i = 0; i < tasksNmr; ++i) {
            tasks[i] = threadPoolSubmit(cpuWorker, &workerContext);
        }
        
        for (int i = 0; i < tasksNmr; ++i) {
            threadPoolTaskWait(tasks[i]);
            threadPoolTaskDelete(tasks[i]);
        }

        mutexLock(&(cpuGpuSync->mutex));

        if (cpuGpuSync->firstCpu <= cpuGpuSync->lastGpu) {
            over = 1;
        }

        mutexUnlock(&(cpuGpuSync->mutex));
    }

    //**************************************************************************

    //**************************************************************************
    // SAVE RESULTS

    LOG("CPU solved %d chains", databaseLen - cpuGpuSync->firstCpu);

    for (int i = cpuGpuSync->firstCpu; i < databaseLen; ++i) {
        scores[order[indexes[i]]] = scoresCpu[i];
    }
    
    //**************************************************************************

    //**************************************************************************
    // CLEAN MEMORY

    free(tasks);
    free(scoresCpu);
    free(database);

    //**************************************************************************

    TIMER_STOP;

    return NULL;
}

static void* cpuWorker(void* param) {

    CpuWorkerContext* context = (CpuWorkerContext*) param;

    int* scores = context->scores;
    int type = context->type;
    Chain* query = context->query;
    Chain** database = context->database;
    int databaseLen = context->databaseLen;
    Scorer* scorer = context->scorer;
    CpuGpuSync* cpuGpuSync = context->cpuGpuSync;
    int useSimd = context->useSimd;

    mutexLock(&(cpuGpuSync->mutex));

    cpuGpuSync->firstCpu = min(cpuGpuSync->firstCpu, databaseLen);

    int start = max(0, cpuGpuSync->firstCpu - CPU_WORKER_STEP);
    int length = cpuGpuSync->firstCpu - start;

    if (start < 0 || start + length < cpuGpuSync->lastGpu) {
        mutexUnlock(&(cpuGpuSync->mutex));
        return NULL;
    }

    cpuGpuSync->firstCpu = start;

    mutexUnlock(&(cpuGpuSync->mutex));

    int status = 0;
    if (useSimd) {
        status = scoreDatabaseSseChar(scores + start, type, query,
            database + start, length, scorer);
    }

    if (!useSimd || status != 0) {
        scoreDatabaseCpu(scores + start, type, query, database + start,
            length, scorer);
    }

    return NULL;
}

//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// GPU KERNELS

__device__ static int gap(int index) {
    return (-gapOpen_ - index * gapExtend_) * (index >= 0);
}

__global__ static void hwSolveShortGpu(int* scores, int2* hBus, int* lengths, 
    int* lengthsPadded, int* offsets, int* indexes, int indexesLen, int block) {

    int tid = threadIdx.x + blockIdx.x * blockDim.x;
    
    if (tid + block * width_ >= indexesLen) {
        return;
    }
    
    int id = indexes[tid + block * width_];
    int cols = lengthsPadded[id];
    int realCols = lengths[id];
    
    int colOff = id % width_;
    int rowOff = offsets[id / width_];
    
    int score = SCORE_MIN;
    
    int4 scrUp;
    int4 affUp;
    int4 mchUp;
    
    int4 scrDown;
    int4 affDown;
    int4 mchDown;
    
    int2 wBus;
    int del;
    
    int lastRow = rows_ - 1;
    
    for (int j = 0; j < cols * 4; ++j) {
        hBus[j * width_ + tid] = make_int2(0, SCORE_MIN);
    }
    
    for (int i = 0; i < rowsPadded_; i += 8) {
    
        scrUp = make_int4(gap(i), gap(i + 1), gap(i + 2), gap(i + 3));
        affUp = INT4_SCORE_MIN;
        mchUp = make_int4(gap(i - 1), gap(i), gap(i + 1), gap(i + 2));
        
        scrDown = make_int4(gap(i + 4), gap(i + 5), gap(i + 6), gap(i + 7));
        affDown = INT4_SCORE_MIN;
        mchDown = make_int4(gap(i + 3), gap(i + 4), gap(i + 5), gap(i + 6));
        
        for (int j = 0; j < cols; ++j) {
        
            int columnCodes = tex2D(seqsTexture, colOff, j + rowOff);
            
            #pragma unroll
            for (int k = 0; k < 4; ++k) {
            
                int validCol = (j * 4 + k) < realCols;
                
                wBus = hBus[(j * 4 + k) * width_ + tid];
                
                char code = (columnCodes >> (k << 3));
                char4 rowScores = tex2D(qpTexture, code, i / 4);
                
                del = max(wBus.x - gapOpen_, wBus.y - gapExtend_);
                affUp.x = max(scrUp.x - gapOpen_, affUp.x - gapExtend_);
                scrUp.x = mchUp.x + rowScores.x; 
                scrUp.x = max(scrUp.x, del);
                scrUp.x = max(scrUp.x, affUp.x);
                mchUp.x = wBus.x;
                if (i + 0 == lastRow && validCol) score = max(score, scrUp.x);
                
                del = max(scrUp.x - gapOpen_, del - gapExtend_);
                affUp.y = max(scrUp.y - gapOpen_, affUp.y - gapExtend_);
                scrUp.y = mchUp.y + rowScores.y; 
                scrUp.y = max(scrUp.y, del);
                scrUp.y = max(scrUp.y, affUp.y);
                mchUp.y = scrUp.x;
                if (i + 1 == lastRow && validCol) score = max(score, scrUp.y);
                
                del = max(scrUp.y - gapOpen_, del - gapExtend_);
                affUp.z = max(scrUp.z - gapOpen_, affUp.z - gapExtend_);
                scrUp.z = mchUp.z + rowScores.z; 
                scrUp.z = max(scrUp.z, del);
                scrUp.z = max(scrUp.z, affUp.z);
                mchUp.z = scrUp.y;
                if (i + 2 == lastRow && validCol) score = max(score, scrUp.z);
                
                del = max(scrUp.z - gapOpen_, del - gapExtend_);
                affUp.w = max(scrUp.w - gapOpen_, affUp.w - gapExtend_);
                scrUp.w = mchUp.w + rowScores.w; 
                scrUp.w = max(scrUp.w, del);
                scrUp.w = max(scrUp.w, affUp.w);
                mchUp.w = scrUp.z;
                if (i + 3 == lastRow && validCol) score = max(score, scrUp.w);

                rowScores = tex2D(qpTexture, code, i / 4 + 1);
                
                del = max(scrUp.w - gapOpen_, del - gapExtend_);
                affDown.x = max(scrDown.x - gapOpen_, affDown.x - gapExtend_);
                scrDown.x = mchDown.x + rowScores.x; 
                scrDown.x = max(scrDown.x, del);
                scrDown.x = max(scrDown.x, affDown.x);
                mchDown.x = scrUp.w;
                if (i + 4 == lastRow && validCol) score = max(score, scrDown.x);
                
                del = max(scrDown.x - gapOpen_, del - gapExtend_);
                affDown.y = max(scrDown.y - gapOpen_, affDown.y - gapExtend_);
                scrDown.y = mchDown.y + rowScores.y; 
                scrDown.y = max(scrDown.y, del);
                scrDown.y = max(scrDown.y, affDown.y);
                mchDown.y = scrDown.x;
                if (i + 5 == lastRow && validCol) score = max(score, scrDown.y);
                
                del = max(scrDown.y - gapOpen_, del - gapExtend_);
                affDown.z = max(scrDown.z - gapOpen_, affDown.z - gapExtend_);
                scrDown.z = mchDown.z + rowScores.z; 
                scrDown.z = max(scrDown.z, del);
                scrDown.z = max(scrDown.z, affDown.z);
                mchDown.z = scrDown.y;
                if (i + 6 == lastRow && validCol) score = max(score, scrDown.z);
                
                del = max(scrDown.z - gapOpen_, del - gapExtend_);
                affDown.w = max(scrDown.w - gapOpen_, affDown.w - gapExtend_);
                scrDown.w = mchDown.w + rowScores.w; 
                scrDown.w = max(scrDown.w, del);
                scrDown.w = max(scrDown.w, affDown.w);
                mchDown.w = scrDown.z;
                if (i + 7 == lastRow && validCol) score = max(score, scrDown.w);
                
                wBus.x = scrDown.w;
                wBus.y = del;
                
                hBus[(j * 4 + k) * width_ + tid] = wBus;
            }
        }
    }
    
    scores[id] = score;
}

__global__ static void nwSolveShortGpu(int* scores, int2* hBus, int* lengths, 
    int* lengthsPadded, int* offsets, int* indexes, int indexesLen, int block) {

    int tid = threadIdx.x + blockIdx.x * blockDim.x;
    
    if (tid + block * width_ >= indexesLen) {
        return;
    }
    
    int id = indexes[tid + block * width_];
    int cols = lengthsPadded[id];
    int realCols = lengths[id];
    
    int colOff = id % width_;
    int rowOff = offsets[id / width_];
    
    int score = SCORE_MIN;
    
    int4 scrUp;
    int4 affUp;
    int4 mchUp;
    
    int4 scrDown;
    int4 affDown;
    int4 mchDown;
    
    int2 wBus;
    int del;
    
    int lastRow = rows_ - 1;

    for (int j = 0; j < cols * 4; ++j) {
        hBus[j * width_ + tid] = make_int2(gap(j), SCORE_MIN);
    }
    
    for (int i = 0; i < rowsPadded_; i += 8) {
    
        scrUp = make_int4(gap(i), gap(i + 1), gap(i + 2), gap(i + 3));
        affUp = INT4_SCORE_MIN;
        mchUp = make_int4(gap(i - 1), gap(i), gap(i + 1), gap(i + 2));
        
        scrDown = make_int4(gap(i + 4), gap(i + 5), gap(i + 6), gap(i + 7));
        affDown = INT4_SCORE_MIN;
        mchDown = make_int4(gap(i + 3), gap(i + 4), gap(i + 5), gap(i + 6));
        
        for (int j = 0; j < cols; ++j) {
        
            int columnCodes = tex2D(seqsTexture, colOff, j + rowOff);
            
            #pragma unroll
            for (int k = 0; k < 4; ++k) {
            
                int lastCol = (j * 4 + k) == (realCols - 1);
                
                wBus = hBus[(j * 4 + k) * width_ + tid];
                
                char code = (columnCodes >> (k << 3));
                char4 rowScores = tex2D(qpTexture, code, i / 4);
                
                del = max(wBus.x - gapOpen_, wBus.y - gapExtend_);
                affUp.x = max(scrUp.x - gapOpen_, affUp.x - gapExtend_);
                scrUp.x = mchUp.x + rowScores.x; 
                scrUp.x = max(scrUp.x, del);
                scrUp.x = max(scrUp.x, affUp.x);
                mchUp.x = wBus.x;
                if (i + 0 == lastRow && lastCol) score = scrUp.x;
                
                del = max(scrUp.x - gapOpen_, del - gapExtend_);
                affUp.y = max(scrUp.y - gapOpen_, affUp.y - gapExtend_);
                scrUp.y = mchUp.y + rowScores.y; 
                scrUp.y = max(scrUp.y, del);
                scrUp.y = max(scrUp.y, affUp.y);
                mchUp.y = scrUp.x;
                if (i + 1 == lastRow && lastCol) score = scrUp.y;
                
                del = max(scrUp.y - gapOpen_, del - gapExtend_);
                affUp.z = max(scrUp.z - gapOpen_, affUp.z - gapExtend_);
                scrUp.z = mchUp.z + rowScores.z; 
                scrUp.z = max(scrUp.z, del);
                scrUp.z = max(scrUp.z, affUp.z);
                mchUp.z = scrUp.y;
                if (i + 2 == lastRow && lastCol) score = scrUp.z;
                
                del = max(scrUp.z - gapOpen_, del - gapExtend_);
                affUp.w = max(scrUp.w - gapOpen_, affUp.w - gapExtend_);
                scrUp.w = mchUp.w + rowScores.w; 
                scrUp.w = max(scrUp.w, del);
                scrUp.w = max(scrUp.w, affUp.w);
                mchUp.w = scrUp.z;
                if (i + 3 == lastRow && lastCol) score = scrUp.w;

                rowScores = tex2D(qpTexture, code, i / 4 + 1);
                
                del = max(scrUp.w - gapOpen_, del - gapExtend_);
                affDown.x = max(scrDown.x - gapOpen_, affDown.x - gapExtend_);
                scrDown.x = mchDown.x + rowScores.x; 
                scrDown.x = max(scrDown.x, del);
                scrDown.x = max(scrDown.x, affDown.x);
                mchDown.x = scrUp.w;
                if (i + 4 == lastRow && lastCol) score = scrDown.x;
                
                del = max(scrDown.x - gapOpen_, del - gapExtend_);
                affDown.y = max(scrDown.y - gapOpen_, affDown.y - gapExtend_);
                scrDown.y = mchDown.y + rowScores.y; 
                scrDown.y = max(scrDown.y, del);
                scrDown.y = max(scrDown.y, affDown.y);
                mchDown.y = scrDown.x;
                if (i + 5 == lastRow && lastCol) score = scrDown.y;
                
                del = max(scrDown.y - gapOpen_, del - gapExtend_);
                affDown.z = max(scrDown.z - gapOpen_, affDown.z - gapExtend_);
                scrDown.z = mchDown.z + rowScores.z; 
                scrDown.z = max(scrDown.z, del);
                scrDown.z = max(scrDown.z, affDown.z);
                mchDown.z = scrDown.y;
                if (i + 6 == lastRow && lastCol) score = scrDown.z;
                
                del = max(scrDown.z - gapOpen_, del - gapExtend_);
                affDown.w = max(scrDown.w - gapOpen_, affDown.w - gapExtend_);
                scrDown.w = mchDown.w + rowScores.w; 
                scrDown.w = max(scrDown.w, del);
                scrDown.w = max(scrDown.w, affDown.w);
                mchDown.w = scrDown.z;
                if (i + 7 == lastRow && lastCol) score = scrDown.w;
                
                wBus.x = scrDown.w;
                wBus.y = del;
                
                hBus[(j * 4 + k) * width_ + tid] = wBus;
            }
        }
    }
    
    scores[id] = score;
}

__global__ static void ovSolveShortGpu(int* scores, int2* hBus, int* lengths, 
    int* lengthsPadded, int* offsets, int* indexes, int indexesLen, int block) {

    int tid = threadIdx.x + blockIdx.x * blockDim.x;
    
    if (tid + block * width_ >= indexesLen) {
        return;
    }
    
    int id = indexes[tid + block * width_];
    int cols = lengthsPadded[id];
    int realCols = lengths[id];
    
    int colOff = id % width_;
    int rowOff = offsets[id / width_];
    
    int score = SCORE_MIN;
    
    int4 scrUp;
    int4 affUp;
    int4 mchUp;
    
    int4 scrDown;
    int4 affDown;
    int4 mchDown;
    
    int2 wBus;
    int del;
    
    int lastRow = rows_ - 1;
    
    for (int j = 0; j < cols * 4; ++j) {
        hBus[j * width_ + tid] = make_int2(0, SCORE_MIN);
    }
    
    for (int i = 0; i < rowsPadded_; i += 8) {
    
        scrUp = INT4_ZERO;
        affUp = INT4_SCORE_MIN;
        mchUp = INT4_ZERO;
        
        scrDown = INT4_ZERO;
        affDown = INT4_SCORE_MIN;
        mchDown = INT4_ZERO;
        
        for (int j = 0; j < cols; ++j) {
        
            int columnCodes = tex2D(seqsTexture, colOff, j + rowOff);
            
            #pragma unroll
            for (int k = 0; k < 4; ++k) {
            
                int lastCol = (j * 4 + k) == (realCols - 1);
                
                wBus = hBus[(j * 4 + k) * width_ + tid];
                
                char code = (columnCodes >> (k << 3));
                char4 rowScores = tex2D(qpTexture, code, i / 4);
                
                del = max(wBus.x - gapOpen_, wBus.y - gapExtend_);
                affUp.x = max(scrUp.x - gapOpen_, affUp.x - gapExtend_);
                scrUp.x = mchUp.x + rowScores.x; 
                scrUp.x = max(scrUp.x, del);
                scrUp.x = max(scrUp.x, affUp.x);
                mchUp.x = wBus.x;
                if (i + 0 == lastRow || lastCol) score = max(score, scrUp.x);
                
                del = max(scrUp.x - gapOpen_, del - gapExtend_);
                affUp.y = max(scrUp.y - gapOpen_, affUp.y - gapExtend_);
                scrUp.y = mchUp.y + rowScores.y; 
                scrUp.y = max(scrUp.y, del);
                scrUp.y = max(scrUp.y, affUp.y);
                mchUp.y = scrUp.x;
                if (i + 1 == lastRow || lastCol) score = max(score, scrUp.y);
                
                del = max(scrUp.y - gapOpen_, del - gapExtend_);
                affUp.z = max(scrUp.z - gapOpen_, affUp.z - gapExtend_);
                scrUp.z = mchUp.z + rowScores.z; 
                scrUp.z = max(scrUp.z, del);
                scrUp.z = max(scrUp.z, affUp.z);
                mchUp.z = scrUp.y;
                if (i + 2 == lastRow || lastCol) score = max(score, scrUp.z);
                
                del = max(scrUp.z - gapOpen_, del - gapExtend_);
                affUp.w = max(scrUp.w - gapOpen_, affUp.w - gapExtend_);
                scrUp.w = mchUp.w + rowScores.w; 
                scrUp.w = max(scrUp.w, del);
                scrUp.w = max(scrUp.w, affUp.w);
                mchUp.w = scrUp.z;
                if (i + 3 == lastRow || lastCol) score = max(score, scrUp.w);

                rowScores = tex2D(qpTexture, code, i / 4 + 1);
                
                del = max(scrUp.w - gapOpen_, del - gapExtend_);
                affDown.x = max(scrDown.x - gapOpen_, affDown.x - gapExtend_);
                scrDown.x = mchDown.x + rowScores.x; 
                scrDown.x = max(scrDown.x, del);
                scrDown.x = max(scrDown.x, affDown.x);
                mchDown.x = scrUp.w;
                if (i + 4 == lastRow || lastCol) score = max(score, scrDown.x);
                
                del = max(scrDown.x - gapOpen_, del - gapExtend_);
                affDown.y = max(scrDown.y - gapOpen_, affDown.y - gapExtend_);
                scrDown.y = mchDown.y + rowScores.y; 
                scrDown.y = max(scrDown.y, del);
                scrDown.y = max(scrDown.y, affDown.y);
                mchDown.y = scrDown.x;
                if (i + 5 == lastRow || lastCol) score = max(score, scrDown.y);
                
                del = max(scrDown.y - gapOpen_, del - gapExtend_);
                affDown.z = max(scrDown.z - gapOpen_, affDown.z - gapExtend_);
                scrDown.z = mchDown.z + rowScores.z; 
                scrDown.z = max(scrDown.z, del);
                scrDown.z = max(scrDown.z, affDown.z);
                mchDown.z = scrDown.y;
                if (i + 6 == lastRow || lastCol) score = max(score, scrDown.z);
                
                del = max(scrDown.z - gapOpen_, del - gapExtend_);
                affDown.w = max(scrDown.w - gapOpen_, affDown.w - gapExtend_);
                scrDown.w = mchDown.w + rowScores.w; 
                scrDown.w = max(scrDown.w, del);
                scrDown.w = max(scrDown.w, affDown.w);
                mchDown.w = scrDown.z;
                if (i + 7 == lastRow || lastCol) score = max(score, scrDown.w);
                
                wBus.x = scrDown.w;
                wBus.y = del;
                
                hBus[(j * 4 + k) * width_ + tid] = wBus;
            }
        }
    }
    
    scores[id] = score;
}

__global__ static void swSolveShortGpu(int* scores, int2* hBus, int* lengths, 
    int* lengthsPadded, int* offsets, int* indexes, int indexesLen, int block) {

    int tid = threadIdx.x + blockIdx.x * blockDim.x;
    
    if (tid + block * width_ >= indexesLen) {
        return;
    }

    int id = indexes[tid + block * width_];
    int cols = lengthsPadded[id];
    
    int colOff = id % width_;
    int rowOff = offsets[id / width_];
    
    int score = 0;
    
    int4 scrUp;
    int4 affUp;
    int4 mchUp;
    
    int4 scrDown;
    int4 affDown;
    int4 mchDown;
    
    int2 wBus;
    int del;
    
    for (int j = 0; j < cols * 4; ++j) {
        hBus[j * width_ + tid] = make_int2(0, 0);
    }
    
    for (int i = 0; i < rowsPadded_; i += 8) {
    
        scrUp = INT4_ZERO;
        affUp = INT4_ZERO;
        mchUp = INT4_ZERO;
        
        scrDown = INT4_ZERO;
        affDown = INT4_ZERO;
        mchDown = INT4_ZERO;
        
        for (int j = 0; j < cols; ++j) {
        
            int columnCodes = tex2D(seqsTexture, colOff, j + rowOff);
           
            #pragma unroll
            for (int k = 0; k < 4; ++k) {
            
                wBus = hBus[(j * 4 + k) * width_ + tid];
                
                char code = (columnCodes >> (k << 3));
                char4 rowScores = tex2D(qpTexture, code, i / 4);
                
                del = max(wBus.x - gapOpen_, wBus.y - gapExtend_);
                affUp.x = max(scrUp.x - gapOpen_, affUp.x - gapExtend_);
                scrUp.x = mchUp.x + rowScores.x; 
                scrUp.x = max(scrUp.x, del);
                scrUp.x = max(scrUp.x, affUp.x);
                scrUp.x = max(scrUp.x, 0);
                mchUp.x = wBus.x;
                score = max(score, scrUp.x);
                
                del = max(scrUp.x - gapOpen_, del - gapExtend_);
                affUp.y = max(scrUp.y - gapOpen_, affUp.y - gapExtend_);
                scrUp.y = mchUp.y + rowScores.y; 
                scrUp.y = max(scrUp.y, del);
                scrUp.y = max(scrUp.y, affUp.y);
                scrUp.y = max(scrUp.y, 0);
                mchUp.y = scrUp.x;
                score = max(score, scrUp.y);

                del = max(scrUp.y - gapOpen_, del - gapExtend_);
                affUp.z = max(scrUp.z - gapOpen_, affUp.z - gapExtend_);
                scrUp.z = mchUp.z + rowScores.z; 
                scrUp.z = max(scrUp.z, del);
                scrUp.z = max(scrUp.z, affUp.z);
                scrUp.z = max(scrUp.z, 0);
                mchUp.z = scrUp.y;
                score = max(score, scrUp.z);
                
                del = max(scrUp.z - gapOpen_, del - gapExtend_);
                affUp.w = max(scrUp.w - gapOpen_, affUp.w - gapExtend_);
                scrUp.w = mchUp.w + rowScores.w; 
                scrUp.w = max(scrUp.w, del);
                scrUp.w = max(scrUp.w, affUp.w);
                scrUp.w = max(scrUp.w, 0);
                mchUp.w = scrUp.z;
                score = max(score, scrUp.w);

                rowScores = tex2D(qpTexture, code, i / 4 + 1);

                del = max(scrUp.w - gapOpen_, del - gapExtend_);
                affDown.x = max(scrDown.x - gapOpen_, affDown.x - gapExtend_);
                scrDown.x = mchDown.x + rowScores.x; 
                scrDown.x = max(scrDown.x, del);
                scrDown.x = max(scrDown.x, affDown.x);
                scrDown.x = max(scrDown.x, 0);
                mchDown.x = scrUp.w;
                score = max(score, scrDown.x);
                
                del = max(scrDown.x - gapOpen_, del - gapExtend_);
                affDown.y = max(scrDown.y - gapOpen_, affDown.y - gapExtend_);
                scrDown.y = mchDown.y + rowScores.y; 
                scrDown.y = max(scrDown.y, del);
                scrDown.y = max(scrDown.y, affDown.y);
                scrDown.y = max(scrDown.y, 0);
                mchDown.y = scrDown.x;
                score = max(score, scrDown.y);
                
                del = max(scrDown.y - gapOpen_, del - gapExtend_);
                affDown.z = max(scrDown.z - gapOpen_, affDown.z - gapExtend_);
                scrDown.z = mchDown.z + rowScores.z; 
                scrDown.z = max(scrDown.z, del);
                scrDown.z = max(scrDown.z, affDown.z);
                scrDown.z = max(scrDown.z, 0);
                mchDown.z = scrDown.y;
                score = max(score, scrDown.z);

                del = max(scrDown.z - gapOpen_, del - gapExtend_);
                affDown.w = max(scrDown.w - gapOpen_, affDown.w - gapExtend_);
                scrDown.w = mchDown.w + rowScores.w; 
                scrDown.w = max(scrDown.w, del);
                scrDown.w = max(scrDown.w, affDown.w);
                scrDown.w = max(scrDown.w, 0);
                mchDown.w = scrDown.z;
                score = max(score, scrDown.w);

                wBus.x = scrDown.w;
                wBus.y = del;
                
                hBus[(j * 4 + k) * width_ + tid] = wBus;
            }
        }
    }

    scores[id] = score;
}

//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// GPU SIMD MODULES

#define NEG 		0x0FF
#define ONE_CELL_COMP_QUAD(f, oe, ie, h, he, hd, sub, gapoe, gape,maxHH) \
				asm("vsub4.s32.s32.s32.sat %0, %1, %2, %3;" : "=r"(f) : "r"(f),"r"(gape), "r"(0));		\
				asm("vsub4.s32.s32.s32.sat %0, %1, %2, %3;" : "=r"(oe) : "r"(ie), "r"(gape), "r"(0));	\
				asm("vsub4.s32.s32.s32.sat %0, %1, %2, %3;" : "=r"(h) : "r"(h), "r"(gapoe), "r"(0));	\
				asm("vmax4.s32.s32.s32 %0, %1, %2, %3;" : "=r"(f) : "r"(f), "r"(h), "r"(0));	\
				asm("vsub4.s32.s32.s32.sat %0, %1, %2, %3;" : "=r"(h) : "r"(he), "r"(gapoe), "r"(0));	\
				asm("vmax4.s32.s32.s32 %0, %1, %2, %3;" : "=r"(oe) : "r"(oe), "r"(h), "r"(0));	\
				asm("vadd4.s32.s32.s32.sat %0, %1, %2, %3;" : "=r"(h) : "r"(hd), "r"(sub), "r"(0));	\
				asm("vmax4.s32.s32.s32 %0, %1, %2, %3;" : "=r"(h) : "r"(h), "r"(f), "r"(0));	\
				asm("vmax4.s32.s32.s32 %0, %1, %2, %3;" : "=r"(h) : "r"(h), "r"(oe), "r"(0));	\
				asm("vmax4.s32.s32.s32 %0, %1, %2, %3;" : "=r"(h) : "r"(h), "r"(0), "r"(0)); 	\
				asm("vmax4.s32.s32.s32 %0, %1, %2, %3;" : "=r"(maxHH) : "r"(maxHH), "r"(h), "r"(0)); \
				asm("mov.s32 %0, %1;" : "=r"(hd) : "r"(he));

#define KITA(a) make_int4((a).x, (a).y, (a).z, (a).w) 	

__global__ static void swSolveShortGpuSimd(int* scores, int2* hBus, 
    int* lengths, int* lengthsPadded, int* offsets, int* indexes,
    int indexesLen, int block) {

    int tid = 4 * (threadIdx.x + blockIdx.x * blockDim.x);
    
    if (tid + block * width_ >= indexesLen) {
        return;
    }
    
    int4 id = make_int4(
        indexes[tid + block * width_], 
        indexes[tid + block * width_ + 1], 
        indexes[tid + block * width_ + 2], 
        indexes[tid + block * width_ + 3]
    );

    int cols = MAX4(
        lengthsPadded[id.x], 
        lengthsPadded[id.y],
        lengthsPadded[id.z], 
        lengthsPadded[id.w]
    );

    int4 colOff = make_int4(
        id.x % width_, 
        id.y % width_, 
        id.z % width_, 
        id.w % width_
    );

    int4 rowOff = make_int4(
        offsets[id.x / width_], 
        offsets[id.y / width_], 
        offsets[id.z / width_], 
        offsets[id.w / width_]
    );

	int4 sa;
	int2 sb;
	int4 h, p, f, h0, p0, f0, sub, sub2, sub3, sub4;
	int2 HD;
	int maxHH;
	int e;

    int tmp = gapOpen_;
	int gapoe = (tmp << 24) | (tmp << 16) | (tmp << 8) | (tmp);

    int tmp1 = gapExtend_;
	int gape = (tmp1 << 24) | (tmp1 << 16) | (tmp1 << 8) | (tmp1);

    
	int4 zero = make_int4(0, 0, 0, 0);
	int2 zero2 = make_int2(0, 0);
	int2 global[3000];
	for (int i = 0; i < cols * 4; i++) {
		global[i] = zero2;
	}

	maxHH = 0;
    for (int i = 0; i < rowsPadded_; i += 8) {
    
        h = zero;
        p = zero;
        f = zero;
        
        h0 = zero;
        p0 = zero;
        f0 = zero;
        
		sb.x = i >> 2;
		sb.y = sb.x + 1;

        for (int j = 0; j < cols; ++j) {
        
            int packx = tex2D(seqsTexture, colOff.x, j + rowOff.x);
            int packy = tex2D(seqsTexture, colOff.y, j + rowOff.y);
            int packz = tex2D(seqsTexture, colOff.z, j + rowOff.z);
            int packw = tex2D(seqsTexture, colOff.w, j + rowOff.w);

            // printf("b codes %d\n", packx);
            // printf("b codes %d\n", packy);
            // printf("b codes %d\n", packz);
            // printf("b codes %d\n", packw);

			for (int k = 0; k < 4; k++) {

				//load data
				HD = global[j * 4 + k];

				//get the (j + k)-th residue

				sa = make_int4(packx & 0x0FF, packy & 0x0FF, packz & 0x0FF, packw & 0x0FF);
				packx >>= 8;
				packy >>= 8;
				packz >>= 8;
				packw >>= 8;

				//loading substitution scores
				sub = KITA(tex2D(qpTexture, sa.x, sb.x));
				sub2 = KITA(tex2D(qpTexture, sa.y, sb.x));
				sub3 = KITA(tex2D(qpTexture, sa.z, sb.x));
				sub4 = KITA(tex2D(qpTexture, sa.w, sb.x));

                /*
                printf("b codes %d %d %d %d\n", sa.x, sa.y, sa.z, sa.w);
                printf("b scores0 %d %d %d %d\n", sub.x, sub.y, sub.z, sub.w);
                printf("b scores0 %d %d %d %d\n", sub2.x, sub2.y, sub2.z, sub2.w);
                printf("b scores0 %d %d %d %d\n", sub3.x, sub3.y, sub3.z, sub3.w);
                printf("b scores0 %d %d %d %d\n", sub4.x, sub4.y, sub4.z, sub4.w);
                */

				sub.x = (sub.x << 24) | ((sub2.x & NEG) << 16)
						| ((sub3.x & NEG) << 8) | sub4.x & NEG; //
				sub.y = (sub.y << 24) | ((sub2.y & NEG) << 16)
						| ((sub3.y & NEG) << 8) | sub4.y & NEG; //
				sub.z = (sub.z << 24) | ((sub2.z & NEG) << 16)
						| ((sub3.z & NEG) << 8) | sub4.z & NEG; //
				sub.w = (sub.w << 24) | ((sub2.w & NEG) << 16)
						| ((sub3.w & NEG) << 8) | sub4.w & NEG; //

				//compute the cell (0, 0);
				ONE_CELL_COMP_QUAD(f.x, e, HD.y, h.x, HD.x, p.x, sub.x, gapoe,
						gape, maxHH)

				//compute cell (0, 1)
				ONE_CELL_COMP_QUAD(f.y, e, e, h.y, h.x, p.y, sub.y, gapoe, gape,
						maxHH)

				//compute cell (0, 2);
				ONE_CELL_COMP_QUAD(f.w, e, e, h.w, h.y, p.w, sub.z, gapoe, gape,
						maxHH)

				//compute cell (0, 3)
				ONE_CELL_COMP_QUAD(f.z, e, e, h.z, h.w, p.z, sub.w, gapoe, gape,
						maxHH)

				//loading substitution score
				sub = KITA(tex2D(qpTexture, sa.x, sb.y));
				sub2 = KITA(tex2D(qpTexture, sa.y, sb.y));
				sub3 = KITA(tex2D(qpTexture, sa.z, sb.y));
				sub4 = KITA(tex2D(qpTexture, sa.w, sb.y));

                /*
                printf("b scores1 %d %d %d %d\n", sub.x, sub.y, sub.z, sub.w);
                printf("b scores1 %d %d %d %d\n", sub2.x, sub2.y, sub2.z, sub2.w);
                printf("b scores1 %d %d %d %d\n", sub3.x, sub3.y, sub3.z, sub3.w);
                printf("b scores1 %d %d %d %d\n", sub4.x, sub4.y, sub4.z, sub4.w);
                */

				sub.x = (sub.x << 24) | ((sub2.x & NEG) << 16)
						| ((sub3.x & NEG) << 8) | sub4.x & NEG; //
				sub.y = (sub.y << 24) | ((sub2.y & NEG) << 16)
						| ((sub3.y & NEG) << 8) | sub4.y & NEG; //
				sub.z = (sub.z << 24) | ((sub2.z & NEG) << 16)
						| ((sub3.z & NEG) << 8) | sub4.z & NEG; //
				sub.w = (sub.w << 24) | ((sub2.w & NEG) << 16)
						| ((sub3.w & NEG) << 8) | sub4.w & NEG; //

				//compute cell(0, 4)
				ONE_CELL_COMP_QUAD(f0.x, e, e, h0.x, h.z, p0.x, sub.x, gapoe,
						gape, maxHH)

				//compute cell(0, 5)
				ONE_CELL_COMP_QUAD(f0.y, e, e, h0.y, h0.x, p0.y, sub.y, gapoe,
						gape, maxHH)

				//compute cell (0, 6)
				ONE_CELL_COMP_QUAD(f0.w, e, e, h0.w, h0.y, p0.w, sub.z, gapoe,
						gape, maxHH)

				//compute cell(0, 7)
				ONE_CELL_COMP_QUAD(f0.z, e, e, h0.z, h0.w, p0.z, sub.w, gapoe,
						gape, maxHH)

				//save data cell(0, 7)
			    global[j * 4 + k] = make_int2(h0.z, e);
			}
        }
    }

    scores[id.x] = (maxHH >> 24) & 0x0ff;
    scores[id.y] = (maxHH >> 16) & 0x0ff;
    scores[id.z] = (maxHH >> 8) & 0x0ff;
    scores[id.w] = maxHH & 0x0ff;
}

//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// QUERY PROFILE

static QueryProfile* createQueryProfile(Chain* query, Scorer* scorer) {

    int rows = chainGetLength(query);
    int rowsGpu = rows + (8 - rows % 8) % 8;
    
    int width = scorerGetMaxCode(scorer) + 1;
    int height = rowsGpu / 4;

    char* row = (char*) malloc(rows * sizeof(char));
    chainCopyCodes(query, row);

    size_t size = width * height * sizeof(char4);
    char4* data = (char4*) malloc(size);
    memset(data, 0, size);
    for (int i = 0; i < height; ++i) {
        for (int j = 0; j < width - 1; ++j) {
            char4 scr;
            scr.x = i * 4 + 0 >= rows ? 0 : scorerScore(scorer, row[i * 4 + 0], j);
            scr.y = i * 4 + 1 >= rows ? 0 : scorerScore(scorer, row[i * 4 + 1], j);
            scr.z = i * 4 + 2 >= rows ? 0 : scorerScore(scorer, row[i * 4 + 2], j);
            scr.w = i * 4 + 3 >= rows ? 0 : scorerScore(scorer, row[i * 4 + 3], j);
            data[i * width + j] = scr;
        }
    }
    
    free(row);
    
    QueryProfile* queryProfile = (QueryProfile*) malloc(sizeof(QueryProfile));
    queryProfile->data = data;
    queryProfile->width = width;
    queryProfile->height = height;
    queryProfile->length = rows;
    queryProfile->size = size;
    
    return queryProfile;
}

static void deleteQueryProfile(QueryProfile* queryProfile) {
    free(queryProfile->data);
    free(queryProfile);
}

static QueryProfileGpu* createQueryProfileGpu(QueryProfile* queryProfile) {

    int width = queryProfile->width;
    int height = queryProfile->height;
    
    size_t size = queryProfile->size;
    char4* data = queryProfile->data;
    cudaArray* dataGpu;
    
    CUDA_SAFE_CALL(cudaMallocArray(&dataGpu, &qpTexture.channelDesc, width, height)); 
    CUDA_SAFE_CALL(cudaMemcpyToArray (dataGpu, 0, 0, data, size, TO_GPU));
    CUDA_SAFE_CALL(cudaBindTextureToArray(qpTexture, dataGpu));
    qpTexture.addressMode[0] = cudaAddressModeClamp;
    qpTexture.addressMode[1] = cudaAddressModeClamp;
    qpTexture.filterMode = cudaFilterModePoint;
    qpTexture.normalized = false;
    
    size_t queryProfileGpuSize = sizeof(QueryProfileGpu);
    QueryProfileGpu* queryProfileGpu = (QueryProfileGpu*) malloc(queryProfileGpuSize);
    queryProfileGpu->data = dataGpu;
    
    return queryProfileGpu;
}

static void deleteQueryProfileGpu(QueryProfileGpu* queryProfileGpu) {
    CUDA_SAFE_CALL(cudaFreeArray(queryProfileGpu->data));
    CUDA_SAFE_CALL(cudaUnbindTexture(qpTexture));
    free(queryProfileGpu);
}

//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// UTILS

static int int2CmpY(const void* a_, const void* b_) {

    int2 a = *((int2*) a_);
    int2 b = *((int2*) b_);
    
    return a.y - b.y;
}

//------------------------------------------------------------------------------
//******************************************************************************

#endif // __CUDACC__

