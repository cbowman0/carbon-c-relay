/*
 * Copyright 2013-2018 Fabian Groffen
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */


#ifndef HAVE_POSIXREGEX_H
#define HAVE_POSIXREGEX_H 1

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#if defined (HAVE_ONIGURAMA)
#include "onigposix.h"
#elif defined (HAVE_PCRE2)
#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>
#include <sys/types.h>
#define regex_t pcre2_regex_t
#define regmatch_t pcre2_regmatch_t
typedef struct {
	pcre2_code *re_pcre2_code;
	pcre2_match_data *re_match_data;
	pcre2_match_context *re_match_context;
	pcre2_jit_stack *re_jit_stack;
	size_t re_nsub;
	char re_owner;
} regex_t;
typedef struct {
	ssize_t rm_so;
	ssize_t rm_eo;
} regmatch_t;
#define REG_EXTENDED 0  /* dummy */
#define REG_ICASE    0  /* dummy */
#define REG_NOSUB    0  /* dummy */
#define REG_ESPACE   PCRE2_ERROR_NOMEMORY
#define regerror(E, R, B, S)  pcre2_get_error_message(E, (PCRE2_UCHAR *)(B), S)
#elif defined (HAVE_PCRE)
#include "pcreposix.h"
#else
#include <regex.h>
#endif

#endif
