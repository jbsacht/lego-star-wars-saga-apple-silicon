#include "saga_controller_keys.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
int main(void) {
    uint64_t diagonal=saga_controller_keys(SAGA_PAD_UP|SAGA_PAD_RIGHT,1);
    assert(diagonal==((UINT64_C(1)<<13)|(UINT64_C(1)<<2)));
    assert(saga_controller_keys(SAGA_PAD_CROSS|SAGA_PAD_SQUARE,1)==
           ((UINT64_C(1)<<32)|(UINT64_C(1)<<4)));
    /* Losing focus or disconnecting must release every held control. */
    assert(saga_controller_keys(0xfff,0)==0);
    assert(saga_controller_keys(0,1)==0);
    assert(saga_controller_keys(SAGA_PAD_MENU,1)==(UINT64_C(1)<<36));
    const unsigned custom[12]={13,1,0,2,37,34,38,40,31,35,36,53};
    assert(saga_controller_keys_with_bindings(SAGA_PAD_CROSS|SAGA_PAD_CIRCLE,1,custom)==
           ((UINT64_C(1)<<37)|(UINT64_C(1)<<34)));
    assert(saga_controller_keys_with_bindings(0xfff,0,custom)==0);
    assert(saga_stick_direction(0.1f,0)==0);
    assert(saga_stick_direction(0.4f,0)==1);
    assert(saga_stick_direction(0.3f,1)==1);
    assert(saga_stick_direction(0.19f,1)==0);
    assert(saga_stick_direction(-0.4f,1)==-1);
    assert(saga_stick_direction(-0.3f,-1)==-1);
    assert(saga_stick_direction(NAN,1)==0);
    puts("Saga controller keyboard mapping: PASS");
}
