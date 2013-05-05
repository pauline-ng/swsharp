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

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "alignment.h"
#include "chain.h"
#include "error.h"
#include "db_alignment.h"
#include "scorer.h"
#include "utils.h"

#include "post_proc.h"

typedef void (*OutputFunction) (Alignment* alignment, FILE* file);

typedef void (*OutputDatabaseFunction) (DbAlignment** dbAlignments, 
    int dbAlignmentsLen, FILE* file);

//******************************************************************************
// PUBLIC
    
//******************************************************************************

//******************************************************************************
// PRIVATE

// utils
static void aligmentStr(char** queryStr, char** targetStr, 
    Alignment* alignment, const char gapItem);
    
// single output
static OutputFunction outputFunction(int type);

static void outputDump(Alignment* alignment, FILE* file);

static void outputPair(Alignment* alignment, FILE* file);

static void outputPlot(Alignment* alignment, FILE* file);

static void outputStat(Alignment* alignment, FILE* file);

static void outputStatPair(Alignment* alignment, FILE* file);

// database output 
static OutputDatabaseFunction outputDatabaseFunction(int type);

static void outputDatabaseLight(DbAlignment** dbAlignments, 
    int dbAlignmentsLen, FILE* file);
    
static void outputDatabaseBlastM0(DbAlignment** dbAlignments, 
    int dbAlignmentsLen, FILE* file);
    
static void outputDatabaseBlastM8(DbAlignment** dbAlignments, 
    int dbAlignmentsLen, FILE* file);
    
static void outputDatabaseBlastM9(DbAlignment** dbAlignments, 
    int dbAlignmentsLen, FILE* file);

//******************************************************************************

//******************************************************************************
// PUBLIC

extern int checkAlignment(Alignment* alignment) {

    Scorer* scorer = alignmentGetScorer(alignment);
    
    Chain* query = alignmentGetQuery(alignment);
    Chain* target = alignmentGetTarget(alignment);

    int queryLen = chainGetLength(query);
    int targetLen = chainGetLength(target);
    
    int queryStart = alignmentGetQueryStart(alignment);
    int queryEnd = alignmentGetQueryEnd(alignment);
    int targetStart = alignmentGetTargetStart(alignment);
    int targetEnd = alignmentGetTargetEnd(alignment);
    
    if (
        queryStart < 0 || queryStart > queryEnd || queryEnd > queryLen ||
        targetStart < 0 || targetStart > targetEnd || targetEnd > targetLen
    ) {
        return 0;
    }
      
    int isQueryGap = 0;
    int isTargetGap = 0;
    int score = 0;
    
    int gapOpen = scorerGetGapOpen(scorer);
    int gapExtend = scorerGetGapExtend(scorer);
    
    int queryIdx = queryEnd;
    int targetIdx = targetEnd;
    
    int i;
    for (i = alignmentGetPathLen(alignment) - 1; i >= 0; --i) {
         
        switch (alignmentGetMove(alignment, i)) {
        case MOVE_LEFT:
            
            score -= isTargetGap ? gapExtend : gapOpen;
            
            targetIdx--;
            
            isQueryGap = 0;
            isTargetGap = 1;
            
            break;
        case MOVE_UP:
            
            score -= isQueryGap ? gapExtend : gapOpen;
            
            queryIdx--;
            
            isQueryGap = 1;
            isTargetGap = 0;
            
            break;
        case MOVE_DIAG:
        
            score += scorerScore(scorer, chainGetCode(query, queryIdx), 
                chainGetCode(target, targetIdx));

            queryIdx--;
            targetIdx--;
            
            isQueryGap = 0;
            isTargetGap = 0;
            
            break;
        default:
            return 0;
        }
    }
    
    //LOG("Checking: %d %d | %d %d", queryIdx + 1, targetIdx + 1, score, 
    //    alignmentGetScore(alignment));
    
    int valid = queryIdx == queryStart - 1 &&
                targetIdx == targetStart - 1 &&
                alignmentGetScore(alignment) == score;
                
    return valid;
}

extern Alignment* readAlignment(char* path) {

    FILE* file = fileSafeOpen(path, "r");
    
    int bytesLen = fileLength(file);
    char* bytes = (char*) malloc(bytesLen * sizeof(char));
    
    int read = fread(bytes, sizeof(char), bytesLen, file);
    ASSERT(read > 0, "IO error");
    
    Alignment* alignment = alignmentDeserialize(bytes);
    
    free(bytes);
    fclose(file);
    
    return alignment;
}

extern void outputAlignment(Alignment* alignment, char* path, int type) {

    FILE* file = path == NULL ? stdout : fileSafeOpen(path, "w");

    OutputFunction function = outputFunction(type);
    function(alignment, file);
    
    if (file != stdout) fclose(file);
}

extern void outputDatabase(DbAlignment** dbAlignments, int dbAlignmentsLen, 
    char* path, int type) {

    FILE* file = path == NULL ? stdout : fileSafeOpen(path, "w");

    OutputDatabaseFunction function = outputDatabaseFunction(type);
    function(dbAlignments, dbAlignmentsLen, file);
    
    if (file != stdout) fclose(file);
}

extern void outputShotgunDatabase(DbAlignment*** dbAlignments, 
    int* dbAlignmentsLens, int dbAlignmentsLen, char* path, int type) {
    
    FILE* file = path == NULL ? stdout : fileSafeOpen(path, "w");

    OutputDatabaseFunction function = outputDatabaseFunction(type);

    int i;
    for (i = 0; i < dbAlignmentsLen; ++i) {
        function(dbAlignments[i], dbAlignmentsLens[i], file);
    }
    
    if (file != stdout) fclose(file);
}

extern void deleteFastaChains(Chain** chains, int chainsLen) {

    int i;
    for (i = 0; i < chainsLen; ++i) {
        chainDelete(chains[i]);
    }
    
    free(chains);
    chains = NULL;
}

extern void deleteShotgunDatabase(DbAlignment*** dbAlignments, 
    int* dbAlignmentsLens, int dbAlignmentsLen) {
    
    int i;
    for (i = 0; i < dbAlignmentsLen; ++i) {
    
        int j;
        for (j = 0; j < dbAlignmentsLens[i]; ++j) {
            dbAlignmentDelete(dbAlignments[i][j]);
        }
        
        free(dbAlignments[i]);
    }
    free(dbAlignments);
    free(dbAlignmentsLens);
}

//******************************************************************************
    
//******************************************************************************
// PRIVATE

//------------------------------------------------------------------------------
// UTILS

static void aligmentStr(char** queryStr, char** targetStr, 
    Alignment* alignment, const char gapItem) {

    Chain* query = alignmentGetQuery(alignment);
    int queryStart = alignmentGetQueryStart(alignment);

    Chain* target = alignmentGetTarget(alignment);
    int targetStart = alignmentGetTargetStart(alignment);

    int pathLen = alignmentGetPathLen(alignment);
    
    int queryIdx = queryStart;
    int targetIdx = targetStart;
    
    *queryStr = (char*) malloc(pathLen * sizeof(char));
    *targetStr = (char*) malloc(pathLen * sizeof(char));
    
    int i;
    for (i = 0; i < pathLen; ++i) {

        char queryChr;
        char targetChr;
        
        switch (alignmentGetMove(alignment, i)) {
        case MOVE_LEFT:
        
            queryChr = gapItem;
            targetChr = chainGetChar(target, targetIdx);

            targetIdx++;

            break;
        case MOVE_UP:
        
            queryChr = chainGetChar(query, queryIdx);
            targetChr = gapItem;
            
            queryIdx++;
            
            break;
        case MOVE_DIAG:
        
            queryChr = chainGetChar(query, queryIdx);
            targetChr = chainGetChar(target, targetIdx);
            
            queryIdx++;
            targetIdx++;
            
            break;
        default:
            // error
            return;
        }
        
        (*queryStr)[i] = queryChr;
        (*targetStr)[i] = targetChr;
    }
}

//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// OUTPUT SINGLE

static OutputFunction outputFunction(int type) {
    switch (type) {
    case SW_OUT_PAIR:
        return outputPair;
    case SW_OUT_STAT_PAIR:
        return outputStatPair;
    case SW_OUT_PLOT:
        return outputPlot;
    case SW_OUT_STAT:
        return outputStat;
    case SW_OUT_DUMP:
        return outputDump;
    default:
        ERROR("Wrong output type");
    }
}

static void outputDump(Alignment* alignment, FILE* file) {

    char* bytes;
    int bytesLen;
    
    alignmentSerialize(&bytes, &bytesLen, alignment);
    fwrite(bytes, sizeof(char), bytesLen, file);
    
    free(bytes);
}

static void outputPair(Alignment* alignment, FILE* file) {
    
    Chain* query = alignmentGetQuery(alignment);
    Chain* target = alignmentGetTarget(alignment);

    int pathLen = alignmentGetPathLen(alignment);
    
    char* queryStr;
    char* targetStr;

    const char gapItem = '-';
    
    aligmentStr(&queryStr, &targetStr, alignment, gapItem);

    const char* queryName = chainGetName(query);
    const char* targetName = chainGetName(target);
    
    int queryStart = alignmentGetQueryStart(alignment);
    int targetStart = alignmentGetTargetStart(alignment);
    int queryEnd = queryStart;
    int targetEnd = targetStart;
        
    char queryLine[50];
    char targetLine[50];
    char markupLine[50];
    
    memset(queryLine, 32, 50);
    memset(targetLine, 32, 50);
    memset(markupLine, 32, 50);
    
    Scorer* scorer = alignmentGetScorer(alignment);
    
    fprintf(file, "\n");
    
    int i;
    for (i = 0; i < pathLen; ++i) {
    
        queryLine[i % 50] = queryStr[i];
        targetLine[i % 50] = targetStr[i];
        
        if (queryStr[i] == targetStr[i]) {
            markupLine[i % 50] = '|';
        } else if (queryStr[i] != gapItem && targetStr[i] != gapItem) {
            if(scorerScore(scorer, chainGetCode(query, queryEnd), 
                chainGetCode(target, targetEnd)) > 0) {
                markupLine[i % 50] = ':';
            } else {
                markupLine[i % 50] = '.';
            }
        } else {
            markupLine[i % 50] = ' ';
        }

        if ((i + 1) % 50 == 0 || i == pathLen - 1) {
        
            fprintf(file, 
                "%-9.9s %9d %-50.50s %9d\n"
                "%19s %-50.50s %9s\n"
                "%-9.9s %9d %-50.50s %9d\n\n", 
                queryName, queryStart + 1, queryLine, queryEnd + 1,
                "", markupLine, "",
                targetName, targetStart + 1, targetLine, targetEnd + 1
            ); 

            queryStart = queryEnd + (queryStr[i] != gapItem);
            targetStart = targetEnd + (targetStr[i] != gapItem);
            
            memset(queryLine, 32, 50 * sizeof(char));
            memset(markupLine, 32, 50 * sizeof(char));
            memset(targetLine, 32, 50 * sizeof(char));
        }

        if (queryStr[i] != gapItem) {
            queryEnd++;
        }
        
        if (targetStr[i] != gapItem) {
            targetEnd++;
        }
    }
    
    free(queryStr);
    free(targetStr);
}

static void outputPlot(Alignment* alignment, FILE* file) {

    const char* queryName = chainGetName(alignmentGetQuery(alignment));
    const char* queryOff = strchr(queryName, ' ');
    int queryLen = queryOff == NULL ? 30 : MIN(30, queryOff - queryName);
        
    int queryStart = alignmentGetQueryStart(alignment);
    int queryEnd = alignmentGetQueryEnd(alignment);
    
    const char* targetName = chainGetName(alignmentGetTarget(alignment));
    const char* targetOff = strchr(targetName, ' ');
    int targetLen = targetOff == NULL ? 30 : MIN(30, targetOff - targetName);

    int targetStart = alignmentGetTargetStart(alignment);
    int targetEnd = alignmentGetTargetEnd(alignment);
    
    fprintf(file, "set terminal png\n");
    fprintf(file, "set output 'output.png'\n");
    fprintf(file, "set autoscale xfix\n");
    fprintf(file, "set autoscale yfix\n");
    fprintf(file, "set yrange [] reverse\n");
    fprintf(file, "set xtics (%d, %d)\n", queryStart, queryEnd);
    fprintf(file, "set ytics (%d, %d)\n", targetStart, targetEnd);
    fprintf(file, "set format x '%%.0f'\n");
    fprintf(file, "set format y '%%.0f'\n");
    fprintf(file, "set tics font 'arial, 10'\n");
    fprintf(file, "set xlabel '%.*s' offset 0,1\n", queryLen, queryName);
    fprintf(file, "set ylabel '%.*s' offset 1,0\n", targetLen, targetName);
    
    fprintf(file, "plot '-' using 1:2 notitle with lines linecolor rgb 'black'\n");

    int queryIdx = queryStart;
    int targetIdx = targetStart;
    int pathLen = alignmentGetPathLen(alignment);
    
    int i;
    for (i = 0; i < pathLen; ++i) {
    
        fprintf(file, "%d %d\n", queryIdx, targetIdx);
    
        char move = alignmentGetMove(alignment, i);
        
        switch (move) {
        case MOVE_LEFT:
            targetIdx++;
            break;
        case MOVE_UP:
            queryIdx++;
            break;
        case MOVE_DIAG:
            queryIdx++;
            targetIdx++;
            break;
        default:
            return;
        }
    }
}

static void outputStat(Alignment* alignment, FILE* file) {

    Chain* query = alignmentGetQuery(alignment);
    Chain* target = alignmentGetTarget(alignment);
    Scorer* scorer = alignmentGetScorer(alignment);
    
    int score = alignmentGetScore(alignment);
    int queryStart = alignmentGetQueryStart(alignment);
    int queryEnd = alignmentGetQueryEnd(alignment);
    int targetStart = alignmentGetTargetStart(alignment);
    int targetEnd = alignmentGetTargetEnd(alignment);
    int pathLen = alignmentGetPathLen(alignment);
    
    int identity = 0;
    int similarity = 0;
    int gaps = 0;
    
    int queryIdx = queryStart;
    int targetIdx = targetStart;
    
    int i;
    for (i = 0; i < pathLen; ++i) {
    
        char move = alignmentGetMove(alignment, i);

        if (move == MOVE_DIAG) {
        
            char queryChr = chainGetChar(query, queryIdx);
            char targetChr = chainGetChar(target, targetIdx);
        
            if (queryChr == targetChr) {
                identity++;
            }
            
            similarity++;
        } else {
            gaps++;
        }
        
        switch (move) {
        case MOVE_LEFT:
            targetIdx++;
            break;
        case MOVE_UP:
            queryIdx++;
            break;
        case MOVE_DIAG:
            queryIdx++;
            targetIdx++;
            break;
        default:
            return;
        }
    }
    
    float idnPct = ((float) identity) / pathLen * 100;
    float simPct = ((float) similarity) / pathLen * 100;
    float gapsPct = ((float) gaps) / pathLen * 100;
        
    fprintf(file, "########################################\n");
    fprintf(file, "#\n");
    fprintf(file, "# Aligned: \n");
    fprintf(file, "# 1: %.80s\n", chainGetName(query));
    fprintf(file, "# 2: %.80s\n", chainGetName(target));
    fprintf(file, "#\n");
    fprintf(file, "# Gap open: %d\n", scorerGetGapOpen(scorer));
    fprintf(file, "# Gap extend: %d\n", scorerGetGapExtend(scorer));
    fprintf(file, "#\n");
    fprintf(file, "# Query length: %d\n", chainGetLength(query));
    fprintf(file, "# Target length: %d\n", chainGetLength(target));
    fprintf(file, "#\n");
    fprintf(file, "# Length: %d\n", pathLen);
    fprintf(file, "# Identity:   %9d/%d (%.2f%%)\n", identity, pathLen, idnPct);
    fprintf(file, "# Similarity: %9d/%d (%.2f%%)\n", similarity, pathLen, simPct);
    fprintf(file, "# Gaps:       %9d/%d (%.2f%%)\n", gaps, pathLen, gapsPct);
    fprintf(file, "# Score: %d\n", score);
    fprintf(file, "# Query: (%d, %d)\n", queryStart, queryEnd);
    fprintf(file, "# Target: (%d, %d)\n", targetStart, targetEnd);
    fprintf(file, "#\n");
    fprintf(file, "########################################\n");
}

static void outputStatPair(Alignment* alignment, FILE* file) {
    outputStat(alignment, file);
    outputPair(alignment, file);
}

//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// OUTPUT DATABASE

static OutputDatabaseFunction outputDatabaseFunction(int type) {
    switch (type) {
    case SW_OUT_DB_LIGHT:
        return outputDatabaseLight;
    case SW_OUT_DB_BLASTM0:
        return outputDatabaseBlastM0;
    case SW_OUT_DB_BLASTM8:
        return outputDatabaseBlastM8;
    case SW_OUT_DB_BLASTM9:
        return outputDatabaseBlastM9;
    default:
        ERROR("Wrong output type");
    }
}

static void outputDatabaseLight(DbAlignment** dbAlignments, 
    int dbAlignmentsLen, FILE* file) {
    
    fprintf(file, "displaying top %d results\n", dbAlignmentsLen);
    
    if (dbAlignmentsLen < 1) {
        return;
    }
    
    Chain* query = dbAlignmentGetQuery(dbAlignments[0]);
    const char* name = chainGetName(query);
    int length = chainGetLength(query);
    
    fprintf(file, "query: %s | lenght: %d\n", name, length);
    
    int i;
    for (i = 0; i < dbAlignmentsLen; ++i) {

        int score = dbAlignmentGetScore(dbAlignments[i]);
        name = chainGetName(dbAlignmentGetTarget(dbAlignments[i]));
        
        fprintf(file, "score: %d -- %s\n", score, name);
    }
}
    
static void outputDatabaseBlastM0(DbAlignment** dbAlignments, 
    int dbAlignmentsLen, FILE* file) {
    
    int i, j;
    
    const char gapItem = '-';
    
    fprintf(file, "\n%s", "Sequences producing significant alignments:");
    fprintf(file, "%27.27s", "Score");
    fprintf(file, "%10.10s\n\n", "Value");
    
    for (i = 0; i < dbAlignmentsLen; ++i) {
    
        const char* name = chainGetName(dbAlignmentGetTarget(dbAlignments[i]));
        int score = dbAlignmentGetScore(dbAlignments[i]);
        float value = dbAlignmentGetValue(dbAlignments[i]);
        
        if (strlen(name) > 57) {
            fprintf(file, " %.56s...%10d%10.0e\n", name, score, value);
        } else {
            fprintf(file, " %.59s%10d%10.0e\n", name, score, value);
        }
    }
    
    fprintf(file, "\n");
    
    for (i = 0; i < dbAlignmentsLen; ++i) {
        
        Chain* query = dbAlignmentGetQuery(dbAlignments[i]);
        Chain* target = dbAlignmentGetTarget(dbAlignments[i]);
        Scorer* scorer = dbAlignmentGetScorer(dbAlignments[i]);
       
        fprintf(file, "> %.78s\n", chainGetName(target));   
        fprintf(file, "Length=%d\n\n", chainGetLength(target));
        
        fprintf(file, " Score = %d,", dbAlignmentGetScore(dbAlignments[i]));
        fprintf(file, " Expect = %.0e\n", dbAlignmentGetValue(dbAlignments[i]));
        
        char* queryStr;
        char* targetStr;
        Alignment* alignment = dbAlignmentToAlignment(dbAlignments[i]);
        aligmentStr(&queryStr, &targetStr, alignment, gapItem);
        alignmentDelete(alignment);
        
        int length = dbAlignmentGetPathLen(dbAlignments[i]);
        int queryIdx = dbAlignmentGetQueryStart(dbAlignments[i]);
        int targetIdx = dbAlignmentGetTargetStart(dbAlignments[i]);
        
        int identities = 0;
        int positives = 0;
        int gaps = 0;
        
        for (j = 0; j < length; ++j) {
        
            if (queryStr[j] == targetStr[j]) {
                identities++;
                positives++;
                queryIdx++;
                targetIdx++;
            } else if (queryStr[j] != gapItem && targetStr[j] != gapItem) {
            
                char a = chainGetCode(query, queryIdx);
                char b = chainGetCode(target, targetIdx);
                
                if(scorerScore(scorer, a, b) > 0) {
                    positives++;
                }
                queryIdx++;
                targetIdx++;
            } else if (targetStr[j] != gapItem) {
                targetIdx++;
                gaps++;
            } else if (queryStr[j] != gapItem) {
                queryIdx++;
                gaps++;
            }
        }
        
        int idnPct = (int) ceil((identities * 100.f) / length);
        int posPct = (int) ceil((positives * 100.f) / length);
        int gapsPct = (int) ceil((gaps * 100.f) / length);
        
        fprintf(file, " ");
        fprintf(file, "Identities = %d/%d (%d%%), ", identities, length, idnPct);
        fprintf(file, "Positives = %d/%d (%d%%), ", positives, length, posPct);
        fprintf(file, "Gaps = %d/%d (%d%%) ", gaps, length, gapsPct);
        fprintf(file, "\n\n");
        
        int queryStart = dbAlignmentGetQueryStart(dbAlignments[i]);
        int targetStart = dbAlignmentGetTargetStart(dbAlignments[i]);
        int queryEnd = queryStart;
        int targetEnd = targetStart;

        char queryLine[61] = { 0 };
        char targetLine[61] = { 0 };
        char markupLine[61] = { 0 };
    
        for (j = 0; j < length; ++j) {
        
            queryLine[j % 60] = queryStr[j];
            targetLine[j % 60] = targetStr[j];
            
            if (queryStr[j] == targetStr[j]) {
                markupLine[j % 60] = queryStr[j];
            } else if (queryStr[j] != gapItem && targetStr[j] != gapItem) {
            
                char a = chainGetCode(query, queryEnd);
                char b = chainGetCode(target, targetEnd);
                
                if(scorerScore(scorer, a, b) > 0) {
                    markupLine[j % 60] = '+';
                } else {
                    markupLine[j % 60] = ' ';
                }
            } else {
                markupLine[j % 60] = ' ';
            }

            if ((j + 1) % 60 == 0 || j == length - 1) {
            
                fprintf(file, 
                    "%s  %-5d%s  %d\n"
                    "%11s %s %s\n"
                    "%s  %-5d%s  %d\n\n", 
                    "Query", queryStart + 1, queryLine, queryEnd + 1,
                    "", markupLine, "",
                    "Sbjct", targetStart + 1, targetLine, targetEnd + 1
                ); 

                queryStart = queryEnd + (queryStr[j] != gapItem);
                targetStart = targetEnd + (targetStr[j] != gapItem);
                
                memset(queryLine, 0, 61 * sizeof(char));
                memset(markupLine, 0, 61 * sizeof(char));
                memset(targetLine, 0, 61 * sizeof(char));
            }

            if (queryStr[j] != gapItem) {
                queryEnd++;
            }
            
            if (targetStr[j] != gapItem) {
                targetEnd++;
            }
        }
        
        fprintf(file, "\n");
        
        free(queryStr);
        free(targetStr);
    }
}
    
static void outputDatabaseBlastM8(DbAlignment** dbAlignments, 
    int dbAlignmentsLen, FILE* file) {
    
    const char gapItem = '-';
     
    int i, j;
    for (i = 0; i < dbAlignmentsLen; ++i) {
    
        int length = dbAlignmentGetPathLen(dbAlignments[i]);
        int gapOpenings = 0;
        int gapOpenedQuery = 0;
        int gapOpenedTarget = 0;
        int identity = 0;
        int mismatches = 0;
        
        char* queryStr;
        char* targetStr;
        Alignment* alignment = dbAlignmentToAlignment(dbAlignments[i]);
        aligmentStr(&queryStr, &targetStr, alignment, gapItem);
        alignmentDelete(alignment);
    
        for (j = 0; j < length; ++j) {
            if (queryStr[j] == targetStr[j]) {
                identity++;
                gapOpenedQuery = 0;
                gapOpenedTarget = 0;
            } else if (queryStr[j] == gapItem) {
                if (!gapOpenedQuery) {
                    gapOpenings++;
                }
                gapOpenedQuery = 1;
                gapOpenedTarget = 0;
            } else if (targetStr[j] == gapItem) {
                if (!gapOpenedTarget) {
                    gapOpenings++;
                }
                gapOpenedQuery = 0;
                gapOpenedTarget = 1;
            } else if (queryStr[j] != targetStr[j]) {
                mismatches++;
            }
        }
        
        free(queryStr);
        free(targetStr);
        
        Chain* query = dbAlignmentGetQuery(dbAlignments[i]);
        const char* queryName = chainGetName(query);
        const char* queryOff = strchr(queryName, ' ');
        int queryLen = queryOff == NULL ? 30 : MIN(30, queryOff - queryName);
        
        Chain* target = dbAlignmentGetTarget(dbAlignments[i]);
        const char* targetName = chainGetName(target);
        const char* targetOff = strchr(targetName, ' ');
        int targetLen = targetOff == NULL ? 30 : MIN(30, targetOff - targetName);

        fprintf(file, "%.*s\t", queryLen, queryName);
        fprintf(file, "%.*s\t", targetLen, targetName);
        fprintf(file, "%.2f\t", (100.f * identity) / length);
        fprintf(file, "%d\t", length);
        fprintf(file, "%d\t", mismatches);
        fprintf(file, "%d\t", gapOpenings);
        fprintf(file, "%d\t", dbAlignmentGetQueryStart(dbAlignments[i]));
        fprintf(file, "%d\t", dbAlignmentGetQueryEnd(dbAlignments[i]));
        fprintf(file, "%d\t", dbAlignmentGetTargetStart(dbAlignments[i]));
        fprintf(file, "%d\t", dbAlignmentGetTargetEnd(dbAlignments[i]));
        fprintf(file, "%.0e\t", dbAlignmentGetValue(dbAlignments[i]));
        fprintf(file, "%-d ", dbAlignmentGetScore(dbAlignments[i]));
        fprintf(file, "\n");
    }
}
    
static void outputDatabaseBlastM9(DbAlignment** dbAlignments, 
    int dbAlignmentsLen, FILE* file) {
    
    fprintf(file, "# Fields:\n"
                  "Query id,Subject id,%% identity,alignment length,mismatches,"
                  "gap openings,q. start,q. end,s. start,s. end,value,score\n");
              
    outputDatabaseBlastM8(dbAlignments, dbAlignmentsLen, file);
}

//------------------------------------------------------------------------------

//******************************************************************************
