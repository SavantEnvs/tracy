// File-input harness for Tracy's bundled libbacktrace (public/libbacktrace: ELF reader, DWARF
// line/function tables, compressed debug sections, debuglink), through its public API as the
// Tracy client uses it on an external binary (public/client/TracyCallstack.cpp):
//   backtrace_create_state_for_file(path) -> backtrace_pcinfo / backtrace_syminfo.
//
// It is a program (AFL file-input target), not a libFuzzer harness, because libbacktrace's state
// cannot be freed by design (backtrace.hpp: "allocates resources that cannot be freed"), so an
// in-process loop would grow without bound. One run = one ELF file:  backtrace_elf <file>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../../public/libbacktrace/backtrace.hpp"

static size_t g_acc;

static void ErrorCb( void*, const char* msg, int ) { g_acc += msg ? strlen( msg ) : 0; }

static int PcCb( void*, uintptr_t pc, uintptr_t lowaddr, const char* filename, int lineno, const char* function )
{
    g_acc += pc + lowaddr + lineno + ( filename ? strlen( filename ) : 0 ) + ( function ? strlen( function ) : 0 );
    return 0;
}

static void SymCb( void*, uintptr_t pc, const char* symname, uintptr_t symval, uintptr_t symsize )
{
    g_acc += pc + symval + symsize + ( symname ? strlen( symname ) : 0 );
}

int main( int argc, char** argv )
{
    if( argc != 2 ) { fprintf( stderr, "usage: %s <elf file>\n", argv[0] ); return 2; }

    // Addresses to resolve: the ELF entry point (e_entry, offset 24 in an ELF64 header) plus a few
    // around it, so lookups land inside the file's own code/line ranges.
    uint64_t entry = 0;
    if( FILE* f = fopen( argv[1], "rb" ) )
    {
        unsigned char hdr[32];
        if( fread( hdr, 1, sizeof( hdr ), f ) == sizeof( hdr ) ) memcpy( &entry, hdr + 24, sizeof( entry ) );
        fclose( f );
    }
    const uintptr_t pcs[] = { (uintptr_t)entry, (uintptr_t)entry + 0x10, (uintptr_t)entry + 0x40, 0x1000, 0x1130, 0x401000 };

    auto state = tracy::backtrace_create_state_for_file( argv[1], 0, ErrorCb, nullptr );
    if( !state ) return 1;
    for( auto pc : pcs )
    {
        tracy::backtrace_pcinfo( state, pc, PcCb, ErrorCb, nullptr );
        tracy::backtrace_syminfo( state, pc, SymCb, ErrorCb, nullptr );
    }
    printf( "%zu\n", g_acc );
    return 0;
}
