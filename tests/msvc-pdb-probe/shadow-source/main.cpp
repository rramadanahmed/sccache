#include "stdafx.h"
#include "after-pch.h"
#if PUBLIC_SHADOW_VALUE != 7 || PUBLIC_CREATOR_ONLY_VALUE != 3
#error The creator PCH macro state was not preserved.
#endif
PublicShadowPchType public_shadow_value{PUBLIC_AFTER_PCH_VALUE};
struct PublicShadowPostPchType {
    char bytes[PUBLIC_AFTER_PCH_VALUE];
};
PublicShadowPostPchType public_shadow_post_type{{1}};
int main() { return static_cast<int>(public_shadow_value.value); }
