#ifndef AIRLIFT_TARGET_H
#define AIRLIFT_TARGET_H

// Support all iOS versions; keep a placeholder for airlift.py parsing compatibility.
#define AIRLIFT_TESTED_BUILDS(X) \
    X(@"0.0", @"00A000")

#define AIRLIFT_SOURCE_PREFIX @"airlift-src-"
#define AIRLIFT_LINK_PREFIX @"airlift-link-"
#define AIRLIFT_RECOVERED_PREFIX @"airlift-recovered-"
#define AIRLIFT_CANARY_PREFIX @"airlift-canary-"

#endif
