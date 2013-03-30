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

#include <mpi.h>
#include <stdlib.h>
#include <string.h>

#include "swsharp/swsharp.h"

#include "mpi_module.h"

//******************************************************************************
// PUBLIC

extern void gatherMpiData(DbAlignment**** dbAlignments, int** dbAlignmentsLen, 
    Chain** queries, int queriesLen, Chain** database, int databaseLen, 
    Scorer* scorer, int maxAlignments);

extern void sendMpiData(DbAlignment*** dbAlignments, int* dbAlignmentsLen, 
    Chain** queries, int queriesLen, Chain** database, int databaseLen);
    
//******************************************************************************

//******************************************************************************
// PRIVATE

static DbAlignment* dbAlignmentFromBytes(char* bytes, Chain** queries, 
    Chain** database, Scorer* scorer);

static void dbAlignmentToBytes(char** bytes, size_t* size, 
    DbAlignment* dbAlignment);

static int dbAlignmentCmp(const void* a_, const void* b_);

//******************************************************************************

//******************************************************************************
// PUBLIC

extern void gatherMpiData(DbAlignment**** dbAlignments, int** dbAlignmentsLen, 
    Chain** queries, int queriesLen, Chain** database, int databaseLen, 
    Scorer* scorer, int maxAlignments) {
    
    int nodes;
    MPI_Comm_size(MPI_COMM_WORLD, &nodes);
        
    int i, j, k;
    
    //**************************************************************************
    // INIT STRUCTURES
    
    DbAlignment**** all = 
        (DbAlignment****) malloc(nodes * sizeof(DbAlignment***));
        
    int** allLens = (int**) malloc(nodes * sizeof(int*));
    
    for (i = 0; i < nodes; ++i) {
        all[i] = (DbAlignment***) malloc(queriesLen * sizeof(DbAlignment**));
        allLens[i] = (int*) malloc(queriesLen * sizeof(int));
    }

    //**************************************************************************
    
    //**************************************************************************
    // RECIEVE
    
    for (i = 0; i < nodes; ++i) {
    
        size_t size;
        MPI_Recv(&size, sizeof(size), MPI_CHAR, i, 1, MPI_COMM_WORLD, NULL);

        char* buffer = (char*) malloc(size);
        MPI_Recv(buffer, size, MPI_CHAR, i, 0, MPI_COMM_WORLD, NULL);

        size_t ptr = 0;
        
        for (j = 0; j < queriesLen; ++j) {
        
            int length;
            memcpy(&length, buffer + ptr, sizeof(int));
            ptr += sizeof(int);
            
            DbAlignment** aligns = 
                (DbAlignment**) malloc(length * sizeof(DbAlignment*));

            for (k = 0; k < length; ++k) {
            
                size_t bytesSize;
                memcpy(&bytesSize, buffer + ptr, sizeof(size_t));
                ptr += sizeof(size_t);
              
                aligns[k] = dbAlignmentFromBytes(buffer + ptr, queries, 
                    database, scorer);
                    
                ptr += bytesSize;
            }
            
            all[i][j] = aligns;
            allLens[i][j] = length;
        }
    }
    
    //**************************************************************************

    //**************************************************************************
    // JOIN

    *dbAlignments = (DbAlignment***) malloc(queriesLen * sizeof(DbAlignment**));
    *dbAlignmentsLen = (int*) malloc(queriesLen * sizeof(int));
    
    for (i = 0; i < queriesLen; ++i) {
        
        int length = 0;
        for (j = 0; j < nodes; ++j) {
            length += allLens[j][i];
        }
        
        (*dbAlignments)[i] = (DbAlignment**) malloc(length * sizeof(DbAlignment*));
        
        int offset = 0;
        
        for (j = 0; j < nodes; ++j) {
            
            size_t size = allLens[j][i] * sizeof(DbAlignment*);
            memcpy((*dbAlignments)[i] + offset, all[j][i], size);
            
            offset += allLens[j][i];
        }
        
        // sort joined
        qsort((*dbAlignments)[i], length, sizeof(DbAlignment*), dbAlignmentCmp);
        
        // delete unnecessary
        if (length >= maxAlignments) {
            
            for (j = maxAlignments; j < length; ++j) {
                dbAlignmentDelete((*dbAlignments)[i][j]);
            }
            
            length = maxAlignments;
        }
        
        (*dbAlignmentsLen)[i] = length;
    }
    
    //**************************************************************************
    
    //**************************************************************************
    // CLEAN MEMORY
    
    for (i = 0; i < nodes; ++i) {
    
        int j;
        for (j = 0; j < queriesLen; ++j) {
            free(all[i][j]);
        }
        
        free(all[i]);
        free(allLens[i]);
    }
    free(allLens);
    
    //**************************************************************************
}

extern void sendMpiData(DbAlignment*** dbAlignments, int* dbAlignmentsLen, 
    Chain** queries, int queriesLen, Chain** database, int databaseLen) {
    
    int i, j;
    
    const int bufferStep = 4096;
    
    size_t bufferSize = bufferStep;
    size_t realSize = 0;
    char* buffer = (char*) malloc(bufferSize);

    size_t ptr = 0;

    for (i = 0; i < queriesLen; ++i) {
        
        realSize += sizeof(int); // dbAlignmentsLen[i]
        
        if (realSize >= bufferSize) {
            bufferSize += (realSize - bufferSize) + bufferStep;
            buffer = (char*) realloc(buffer, bufferSize);
        }

        memcpy(buffer + ptr, &(dbAlignmentsLen[i]), sizeof(int));
        ptr += sizeof(int);

        for (j = 0; j < dbAlignmentsLen[i]; ++j) {
        
            size_t bytesSize;
            char* bytes;
            
            dbAlignmentToBytes(&bytes, &bytesSize, dbAlignments[i][j]);
            
            realSize += sizeof(size_t);
            realSize += bytesSize;
            
            if (realSize >= bufferSize) {
                bufferSize += (realSize - bufferSize) + bufferStep;
                buffer = (char*) realloc(buffer, bufferSize);
            }
            
            memcpy(buffer + ptr, &bytesSize, sizeof(size_t));
            ptr += sizeof(size_t);
            
            memcpy(buffer + ptr, bytes, bytesSize);
            ptr += bytesSize;
        }
    }
    
    MPI_Send(&realSize, sizeof(size_t), MPI_CHAR, MASTER_NODE, 1, MPI_COMM_WORLD);
    MPI_Send(buffer, realSize, MPI_CHAR, MASTER_NODE, 0, MPI_COMM_WORLD);
    
    free(buffer);
}

//******************************************************************************

//******************************************************************************
// PRIVATE

//------------------------------------------------------------------------------
// SERIALIZATION

static DbAlignment* dbAlignmentFromBytes(char* bytes, Chain** queries, 
    Chain** database, Scorer* scorer) {

    int ptr = 0;
    
    int queryStart;
    memcpy(&queryStart, bytes + ptr, sizeof(int));
    ptr += sizeof(int);
    
    int queryEnd;
    memcpy(&queryEnd, bytes + ptr, sizeof(int));
    ptr += sizeof(int);

    int queryIdx;
    memcpy(&queryIdx, bytes + ptr, sizeof(int));
    ptr += sizeof(int);

    int targetStart;
    memcpy(&targetStart, bytes + ptr, sizeof(int));
    ptr += sizeof(int);

    int targetEnd;
    memcpy(&targetEnd, bytes + ptr, sizeof(int));
    ptr += sizeof(int);

    int targetIdx;
    memcpy(&targetIdx, bytes + ptr, sizeof(int));
    ptr += sizeof(int);
    
    int score;
    memcpy(&score, bytes + ptr, sizeof(int));
    ptr += sizeof(int);
    
    float value;
    memcpy(&value, bytes + ptr, sizeof(float));
    ptr += sizeof(float);
    
    int pathLen;
    memcpy(&pathLen, bytes + ptr, sizeof(int));
    ptr += sizeof(int);
    
    char* path = (char*) malloc(pathLen);
    memcpy(path, bytes + ptr, pathLen);
    
    Chain* query = queries[queryIdx];
    Chain* target = database[targetIdx];

    DbAlignment* dbAlignment = dbAlignmentCreate(query, queryStart, queryEnd,
        queryIdx, target, targetStart, targetEnd, targetIdx, value, score, 
        scorer, path, pathLen);
    
    return dbAlignment;
}

static void dbAlignmentToBytes(char** bytes, size_t* size, 
    DbAlignment* dbAlignment) {
    
    // int 3 query
    // int 3 target
    // int 1 score
    // float 1 value
    // int 1 pathLen
    // char pathLen path
    *size = sizeof(int) * 8 + sizeof(float) + dbAlignmentGetPathLen(dbAlignment);
    *bytes = (char*) malloc(*size);

    int ptr = 0;

    int queryStart = dbAlignmentGetQueryStart(dbAlignment);
    memcpy(*bytes + ptr, &queryStart, sizeof(int));
    ptr += sizeof(int);
    
    int queryEnd = dbAlignmentGetQueryEnd(dbAlignment);
    memcpy(*bytes + ptr, &queryEnd, sizeof(int));
    ptr += sizeof(int);
    
    int queryIdx = dbAlignmentGetQueryIdx(dbAlignment);
    memcpy(*bytes + ptr, &queryIdx, sizeof(int));
    ptr += sizeof(int);
    
    int targetStart = dbAlignmentGetTargetStart(dbAlignment);
    memcpy(*bytes + ptr, &targetStart, sizeof(int));
    ptr += sizeof(int);

    int targetEnd = dbAlignmentGetTargetEnd(dbAlignment);
    memcpy(*bytes + ptr, &targetEnd, sizeof(int));
    ptr += sizeof(int);

    int targetIdx = dbAlignmentGetTargetIdx(dbAlignment);
    memcpy(*bytes + ptr, &targetIdx, sizeof(int));
    ptr += sizeof(int);

    int score = dbAlignmentGetScore(dbAlignment);
    memcpy(*bytes + ptr, &score, sizeof(int));
    ptr += sizeof(int);
    
    float value = dbAlignmentGetValue(dbAlignment);
    memcpy(*bytes + ptr, &value, sizeof(float));
    ptr += sizeof(float);
    
    int pathLen = dbAlignmentGetPathLen(dbAlignment);
    memcpy(*bytes + ptr, &pathLen, sizeof(int));
    ptr += sizeof(int);

    dbAlignmentCopyPath(dbAlignment, *bytes + ptr);
    ptr += pathLen;
}

//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// UTILS

static int dbAlignmentCmp(const void* a_, const void* b_) {

    DbAlignment* a = *((DbAlignment**) a_);
    DbAlignment* b = *((DbAlignment**) b_);
    
    int va = dbAlignmentGetValue(a);
    int vb = dbAlignmentGetValue(b);

    if (va < vb) return -1;
    if (va > vb) return 1;
    return 0;
}

//------------------------------------------------------------------------------
//******************************************************************************
