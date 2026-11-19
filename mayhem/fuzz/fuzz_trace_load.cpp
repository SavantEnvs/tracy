// Fuzz the .tracy trace-file loader the way tracy-csvexport / tracy-update / the profiler GUI
// open a saved trace: tracy::FileRead::Open(path) -> tracy::Worker(FileRead&), then walk the
// loaded data with the public getters csvexport uses.
//
// FileRead only takes a path (it fopen()s the file and streams LZ4/zstd blocks from it on worker
// threads), so each input is written to a private scratch file under $TMPDIR first.
//
// Built twice: as fuzz_trace_load, and with -DTRACE_WRITE as fuzz_trace_write, which also
// re-serializes the loaded trace with Worker::Write + FileWrite (the tracy-update path).
//
// Rejections are the loader's own documented exceptions (server/TracyFileRead.hpp,
// server/TracyWorker.hpp): NotTracyDump, FileReadError, UnsupportedVersion, LegacyVersion,
// LoadFailure. Anything else propagates and aborts.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <memory>
#include <string>
#include <thread>

#include "TracyFileRead.hpp"
#include "TracyFileWrite.hpp"
#include "TracyWorker.hpp"

static std::string g_in;
static std::string g_out;

static std::string MakeScratch( const char* stem )
{
    const char* dir = getenv( "TMPDIR" );
    if( !dir || !*dir ) dir = "/tmp";
    std::string p = std::string( dir ) + "/" + stem + "-XXXXXX";
    int fd = mkstemp( p.data() );
    if( fd < 0 ) { perror( "mkstemp" ); abort(); }
    close( fd );
    return p;
}

extern "C" int LLVMFuzzerInitialize( int*, char*** )
{
    g_in = MakeScratch( "tracy-in" );
    g_out = MakeScratch( "tracy-out" );
    return 0;
}

static volatile size_t g_sink;

static void Walk( const tracy::Worker& worker )
{
    size_t acc = worker.GetCaptureName().size() + worker.GetCaptureProgram().size();
    acc += (size_t)worker.GetLastTime() + worker.GetZoneCount();

    for( auto& m : worker.GetMessages() )
    {
        acc += strlen( worker.GetString( m->ref ) ) + (size_t)m->time;
    }
    for( auto& t : worker.GetThreadData() )
    {
        acc += strlen( worker.GetThreadName( t->id ) ) + t->timeline.size();
    }
    for( auto& p : worker.GetPlots() )
    {
        acc += p->data.size();
    }
    for( auto& fd : worker.GetFrames() )
    {
        acc += strlen( worker.GetString( fd->name ) );
        const auto fsz = worker.GetFullFrameCount( *fd );
        for( size_t i=0; i<fsz && i<64; i++ ) acc += (size_t)worker.GetFrameTime( *fd, i );
    }
    for( auto& it : worker.GetSourceLocationZones() )
    {
        const auto& srcloc = worker.GetSourceLocation( it.first );
        acc += strlen( worker.GetString( srcloc.file ) ) + srcloc.line;
        acc += strlen( worker.GetZoneName( srcloc ) );
        size_t n = 0;
        for( const auto& z : it.second.zones )
        {
            const auto ev = z.Zone();
            acc += (size_t)( ev->End() - ev->Start() ) + z.Thread();
            if( worker.HasZoneExtra( *ev ) )
            {
                const auto& text = worker.GetZoneExtra( *ev ).text;
                if( text.Active() ) acc += strlen( worker.GetString( text ) );
            }
            if( ++n == 256 ) break;
        }
    }
    g_sink = acc;
}

extern "C" int LLVMFuzzerTestOneInput( const uint8_t* data, size_t size )
{
    FILE* f = fopen( g_in.c_str(), "wb" );
    if( !f ) { perror( "fopen" ); abort(); }
    if( size && fwrite( data, 1, size, f ) != size ) { perror( "fwrite" ); abort(); }
    fclose( f );

    try
    {
        std::unique_ptr<tracy::FileRead> fr( tracy::FileRead::Open( g_in.c_str() ) );
        if( !fr ) { perror( "FileRead::Open" ); abort(); }
        tracy::Worker worker( *fr );
        // The background tasks (zone statistics, context-switch usage, ...) are part of loading
        // a trace; let them finish before reading their results.
        while( !worker.IsBackgroundDone() ) std::this_thread::yield();
        Walk( worker );
#ifdef TRACE_WRITE
        std::unique_ptr<tracy::FileWrite> fw( tracy::FileWrite::Open( g_out.c_str(), tracy::FileCompression::Fast, 1, 1 ) );
        if( !fw ) { perror( "FileWrite::Open" ); abort(); }
        worker.Write( *fw, false );
#endif
    }
    catch( const tracy::NotTracyDump& ) {}
    catch( const tracy::FileReadError& ) {}
    catch( const tracy::UnsupportedVersion& ) {}
    catch( const tracy::LegacyVersion& ) {}
    catch( const tracy::LoadFailure& ) {}
    return 0;
}
