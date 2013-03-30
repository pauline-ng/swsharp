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

#include "swsharp/swsharp.h"

#include "evalue.h"

//******************************************************************************
// PUBLIC

//******************************************************************************

//******************************************************************************
// PRIVATE

//******************************************************************************

//******************************************************************************
// PUBLIC

extern void eValues(float* values, int* scores, Chain* query, 
    Chain** database, int databaseLen, Scorer* scorer) {
    
    int i;
    for (i = 0; i < databaseLen; ++i) {
        values[i] = -scores[i];
    }
}

//******************************************************************************

//******************************************************************************
// PRIVATE

//******************************************************************************
