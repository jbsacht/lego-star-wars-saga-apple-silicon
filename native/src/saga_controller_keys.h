#ifndef SAGA_CONTROLLER_KEYS_H
#define SAGA_CONTROLLER_KEYS_H
#include <stdint.h>

/* Default App Store keyboard bindings. This fallback supplies player one;
 * it deliberately does not claim to provide analog movement or native HID. */
enum {
    SAGA_PAD_UP=1, SAGA_PAD_DOWN=2, SAGA_PAD_LEFT=4, SAGA_PAD_RIGHT=8,
    SAGA_PAD_CROSS=16, SAGA_PAD_CIRCLE=32, SAGA_PAD_SQUARE=64,
    SAGA_PAD_TRIANGLE=128, SAGA_PAD_L1=256, SAGA_PAD_R1=512,
    SAGA_PAD_MENU=1024, SAGA_PAD_BACK=2048
};
static inline uint64_t saga_controller_keys_with_bindings(unsigned buttons, int active,
                                                         const unsigned keys[12]) {
    if (!active) return 0;
    uint64_t result=0;
    for(unsigned i=0;i<12;++i)
        if((buttons&(1u<<i)) && keys[i]<64)result|=UINT64_C(1)<<keys[i];
    return result;
}
static inline uint64_t saga_controller_keys(unsigned buttons, int active) {
    static const unsigned keys[]={13,1,0,2,32,38,4,40,59,49,36,53};
    return saga_controller_keys_with_bindings(buttons,active,keys);
}
/* Separate press/release thresholds prevent stick noise from chattering. */
static inline int saga_stick_direction(float value, int previous) {
    if(value>0.35f)return 1;
    if(value< -0.35f)return -1;
    if(previous>0 && value>0.20f)return 1;
    if(previous<0 && value< -0.20f)return -1;
    return 0;
}
#endif
