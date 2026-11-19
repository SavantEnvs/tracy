// Fuzz tracy::ParseBroadcastMessage: the decoder for the UDP discovery packets every Tracy
// client broadcasts and the profiler/capture tools listen for (server/TracyBroadcast.cpp).
#include <stdint.h>
#include <string.h>

#include "TracyBroadcast.hpp"

static volatile size_t g_sink;

extern "C" int LLVMFuzzerTestOneInput( const uint8_t* data, size_t size )
{
    auto msg = tracy::ParseBroadcastMessage( (const char*)data, size );
    if( msg )
    {
        g_sink = msg->protocolVersion + msg->listenPort + msg->pid + (size_t)msg->activeTime
               + strnlen( msg->programName, sizeof( msg->programName ) );
    }
    return 0;
}
