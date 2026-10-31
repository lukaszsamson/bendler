// Bendler's names for the constructor ids the codec needs, spelled with
// CID(Name), the interface Bend substitutes in an effect's C: its CID_
// macro spellings are internal and change between releases. This is the
// shim's first effect and always used, so the shared headers it includes
// below see these first; bendler_common.h refuses to build otherwise.
#define BL_CID_NONE CID(None)
#define BL_CID_SOME CID(Some)
#define BL_CID_DONE CID(Done)
#define BL_CID_FAIL CID(Fail)
#define BL_CID_TRUE CID(True)
#define BL_CID_FALSE CID(False)
#define BL_CID_UNIT CID(Unit)
#define BL_CID_TUPLE CID(Tuple)
#ifdef CID(Con)
#define BL_CID_NIL CID(Nil)
#define BL_CID_CON CID(Con)
#endif
#include BENDLER_TRANSPORT
Term bendler_fn_run(Env e, Term* f, IoWork* w) { return bl_frame_next(e, w); }
static void __attribute__((constructor)) bendler_fn_use(void) { io_eff(CID(Bendler.fn), bendler_fn_run); }
