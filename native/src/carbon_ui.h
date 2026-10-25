#ifndef LP32_CARBON_UI_H
#define LP32_CARBON_UI_H
#include <stdint.h>
void carbon_ui_show(void *window);
void carbon_ui_hide(void *window);
void carbon_ui_dispose(void *window);
int32_t carbon_ui_run_modal(void *window);
int carbon_ui_stop_modal(void *window);
int carbon_ui_is_visible(void *window);
void carbon_ui_use_native(void *window);
int32_t carbon_ui_show_sheet(void *sheet, void *parent);
int32_t carbon_ui_hide_sheet(void *sheet);
#endif

void carbon_ui_set_background(void *window, unsigned short r, unsigned short g, unsigned short b);

void carbon_ui_screen_updates(int enabled);

int carbon_ui_resize_limits(void *window, float *minimum, float *maximum, int set);

void carbon_ui_bring_front(void *window);

void carbon_ui_game_prepare(void *window);
int carbon_ui_game_geometry(void *window, int x, int y, int size);
int carbon_ui_gl_attach(void *context, void *window);
int carbon_ui_gl_operation(void *context, int operation);
void *carbon_ui_gl_window(void *context);

int carbon_ui_gl_fullscreen(void *context);

int carbon_ui_game_bounds(void *window, void *rect, int global);

int carbon_ui_gl_rect(const unsigned int *rect, int viewport);

int carbon_ui_game_active(void *window);
void *carbon_ui_front_window(void);
void *carbon_ui_next_window(void *native);
int carbon_ui_pump_sleep(unsigned int microseconds);
int carbon_ui_game_keys(void *keys);
void carbon_ui_begin_deactivation(void);
void carbon_ui_end_deactivation(void);
