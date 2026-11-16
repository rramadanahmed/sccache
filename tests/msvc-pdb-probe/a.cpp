#include "pch.h"
int public_a() {
    std::vector<int> values{public_pch_value(), 4};
    return values[0] + values[1];
}
