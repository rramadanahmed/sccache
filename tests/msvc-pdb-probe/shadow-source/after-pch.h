#pragma once
#if PUBLIC_SHADOW_VALUE == 7
#include "selected-after.h"
#else
#error The wrong PCH macro state selected the post-PCH dependency.
#endif
