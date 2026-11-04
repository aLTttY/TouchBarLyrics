#import "TBPrivate.h"

void (*tbl_DFRSetControlStripPresence)(id, BOOL) = NULL;
BOOL (*tbl_DFRGetControlStripPresence)(id) = NULL;
void (*tbl_DFRCloseBox)(BOOL) = NULL;

BOOL TBLoadDFRFoundation(void) {
    static BOOL loaded = NO, tried = NO;
    if (tried) return loaded;
    tried = YES;
    void *h = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY);
    if (!h) return NO;
    tbl_DFRSetControlStripPresence = (void (*)(id, BOOL))dlsym(h, "DFRElementSetControlStripPresenceForIdentifier");
    tbl_DFRGetControlStripPresence = (BOOL (*)(id))dlsym(h, "DFRElementGetControlStripPresenceForIdentifier");
    tbl_DFRCloseBox = (void (*)(BOOL))dlsym(h, "DFRSystemModalShowsCloseBoxWhenFrontMost");
    loaded = tbl_DFRSetControlStripPresence && tbl_DFRCloseBox;
    return loaded;
}
