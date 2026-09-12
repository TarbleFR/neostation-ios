#!/usr/bin/env python3
"""Harden the pinned native RPCS3 savestate pipeline, without changing its format."""
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
assets = Path(__file__).resolve().parent / 'rpcs3'

def patch(path, marker, changes):
    target = root / path
    text = target.read_text()
    if marker in text:
        return
    for old, new in changes:
        if text.count(old) != 1:
            raise SystemExit(f'{path}: expected one patch anchor: {old[:100]!r}')
        text = text.replace(old, new, 1)
    target.write_text(text)

for name in ('NeoStationSavestateIO.h', 'NeoStationSavestateStatus.h'):
    (root / 'rpcs3/ios' / name).write_text((assets / name).read_text())

patch('rpcs3/util/serialization_ext.cpp', 'NEOSTATION_SAVESTATE_IO_V1', [
    ('#include <zstd.h>', '#include <zstd.h>\n#include "ios/NeoStationSavestateIO.h" // NEOSTATION_SAVESTATE_IO_V1'),
    ('''struct compressed_zstd_stream_data
{
	ZSTD_DCtx* m_zd{};
	ZSTD_DStream* m_zs{};
	lf_queue<std::vector<u8>> m_queued_data_to_process;
	lf_queue<std::vector<u8>> m_queued_data_to_write;
};''', '''// Header-only enumeration also destroys this owner, releasing its decoder.
struct compressed_zstd_stream_data : neostation::savestate::decoder_context {};'''),
    ('''		m_compression_threads.clear();
		m_file_writer_thread.reset();''', '''		m_compression_threads.clear();
		m_file_writer_thread.reset();
		m_input_buffer_index = 0;
		m_output_buffer_index = 0;'''),
    ('''		m_zd = ZSTD_createDCtx();
		m_stream->m_zs = ZSTD_createDStream();
		m_read_inited = true;
		m_errored = false;''', '''		m_zd = ZSTD_createDCtx();
		m_read_inited = m_zd != nullptr;
		m_errored = !m_read_inited;'''),
    ('''bool compressed_zstd_serialization_file_handler::handle_file_op(utils::serial& ar, usz pos, usz size, const void* data)
{
	if (ar.is_writing())
	{
		initialize(ar);

		if (m_errored)
		{
			return false;
		}''', '''bool compressed_zstd_serialization_file_handler::handle_file_op(utils::serial& ar, usz pos, usz size, const void* data)
{
	if (ar.is_writing())
	{
		initialize(ar);

		if (m_errored)
		{
			// Keep serialization bounded while workers drain. finalize() reports
			// the failure after joining them, before the pending file can commit.
			ar.seek_end();
			ar.data_offset = ar.pos;
			ar.data.clear();
			return true;
		}'''),
    ('''void compressed_zstd_serialization_file_handler::finalize(utils::serial& ar)
{
	handle_file_op(ar, 0, umax, nullptr);

	if (!m_stream)
	{
		return;
	}

	auto& m_zd = m_stream->m_zd;

	if (m_read_inited)
	{
		//ZSTD_decompressEnd(m_stream->m_zd);
		ensure(ZSTD_freeDCtx(m_zd));
		m_read_inited = false;
		return;
	}''', '''void compressed_zstd_serialization_file_handler::finalize(utils::serial& ar)
{
	if (m_read_inited)
	{
		m_stream->reset();
		m_read_inited = false;
		return;
	}
	if (!m_write_inited) return;
	handle_file_op(ar, 0, umax, nullptr);'''),
    ('''	m_file->sync();
}

void compressed_zstd_serialization_file_handler::stream_data_prepare_thread_op''', '''	m_file->sync();
	if (m_errored)
	{
		fmt::throw_exception("RPCS3 savestate compression/write failed; incomplete temporary file was not committed");
	}
}

void compressed_zstd_serialization_file_handler::stream_data_prepare_thread_op'''),
    ('''		stream_data.resize(::ZSTD_compressBound(data->size()));
		const usz out_size = ZSTD_compressCCtx(m_zc, stream_data.data(), stream_data.size(), data->data(), data->size(), ZSTD_btultra);

		ensure(!ZSTD_isError(out_size) && out_size);

		if (m_errored)
		{
			break;
		}

		stream_data.resize(out_size);''', '''		// Never abandon a slot on error: the ordered writer/finalizer must drain
		// every submitted input. A one-byte placeholder is discarded by writer.
		usz out_size = 0;
		if (m_zc && !m_errored)
		{
			stream_data.resize(::ZSTD_compressBound(data->size()));
#ifdef RPCS3_IOS
			constexpr int level = neostation::savestate::compression_level;
#else
			constexpr int level = ZSTD_btultra;
#endif
			out_size = ZSTD_compressCCtx(m_zc, stream_data.data(), stream_data.size(), data->data(), data->size(), level);
		}
		if (!out_size || ZSTD_isError(out_size))
		{
			m_errored = true;
			stream_data.assign(1, 0);
		}
		else stream_data.resize(out_size);'''),
    ('''		m_file->write(*data);
	}
}

usz compressed_zstd_serialization_file_handler::get_size''', '''		if (!m_errored && !neostation::savestate::write_complete(
			[this](const void* bytes, usz count) { return m_file->write(bytes, count); }, data->data(), data->size()))
		{
			m_errored = true;
		}
	}
}

usz compressed_zstd_serialization_file_handler::get_size'''),
])

patch('rpcs3/util/serialization_ext.cpp', 'NEOSTATION_ZSTD_INVALID_FRAME_V1', [
    ('\t\t\tbool need_more_file_memory = false;\n\n\t\t\tZSTD_outBuffer', '\t\t\tZSTD_outBuffer'),
    ('\t\t\t\tneed_more_file_memory = true;\n'
     '\t\t\t\t// finalize(ar);\n'
     '\t\t\t\t// m_errored = true;\n'
     '\t\t\t\t// sys_log.error("Failure of compressed data reading. (res=%d, read_size=0x%x, avail_in=0x%x, avail_out=0x%x, ar=%s)", res, read_size, avail_in, avail_out, ar);\n'
     '\t\t\t\t// return read_size;',
     '\t\t\t\t// NEOSTATION_ZSTD_INVALID_FRAME_V1: errors are not a request\n'
     '\t\t\t\t// for more input. Do not buffer the rest of a damaged file.\n'
     '\t\t\t\tm_errored = true;\n\t\t\t\treturn read_size;'),
    ('\t\t\tm_stream_data_index = next_in - m_stream_data.data();\n\n'
     '\t\t\tif (need_more_file_memory)\n\t\t\t{\n\t\t\t\tbreak;\n\t\t\t}',
     '\t\t\tm_stream_data_index = next_in - m_stream_data.data();'),
])

# Disk-full is a recoverable save failure, not a fatal RPCS3 thread exit.
# finalize leaves is_valid() false; System.cpp checks it before commit.
patch('rpcs3/util/serialization_ext.cpp', 'NEOSTATION_SAVE_RECOVERABLE_IO_V1', [
    ('fmt::throw_exception("RPCS3 savestate compression/write failed; incomplete temporary file was not committed");',
     '// NEOSTATION_SAVE_RECOVERABLE_IO_V1: caller must not commit.\n\t\treturn;'),
])

patch('rpcs3/Emu/System.cpp', 'NEOSTATION_SAVESTATE_TRANSACTION_V1', [
    ('#include "Emu/savestate_utils.hpp"', '#include "Emu/savestate_utils.hpp"\n#include <atomic>\n#include "ios/NeoStationSavestateStatus.h" // NEOSTATION_SAVESTATE_TRANSACTION_V1'),
    ('auto join_ended = std::make_shared<bool>(false);', 'auto join_ended = std::make_shared<std::atomic_bool>(false);'),
    ('\t\t\t\tar.m_file_handler->finalize(ar);',
     '\t\t\t\tar.m_file_handler->finalize(ar);\n'
     '\t\t\t\tif (!ar.m_file_handler->is_valid())\n'
     '\t\t\t\t{\n'
     '\t\t\t\t\tsavestate = false; // Joined before the pending-file commit check.\n'
     '\t\t\t\t\tneostation::savestate::current.error("Savestate compression or disk writing failed. The incomplete temporary file was not committed.");\n'
     '\t\t\t\t\tsys_log.error("Savestate write failed; retaining previous savestates.");\n'
     '\t\t\t\t}'),
    ('sys_log.error("Failed to savestate: failed to lock SPU threads execution.");',
     'sys_log.error("Failed to savestate: failed to lock SPU threads execution.");\n'
     '\t\t\t\t\tneostation::savestate::current.error("SPU threads could not reach a safe point. Retry outside active cutscenes. Some games require SPU Savestates-Compatible Mode, with a performance cost.");'),
    ('if (vdec_error)\n\t\t\t\t\t{',
     'if (vdec_error)\n\t\t\t\t\t{\n'
     '\t\t\t\t\t\tneostation::savestate::current.error("An HLE video decoder is active and cannot be captured safely. Finish or skip the cutscene before retrying.");'),
    ('if (savedata_error)\n\t\t\t\t\t{',
     'if (savedata_error)\n\t\t\t\t\t{\n'
     '\t\t\t\t\t\tneostation::savestate::current.error("The game is writing its own save data. Wait for its saving indicator to disappear, then retry.");'),
    ('if (sysutil_error)\n\t\t\t\t\t{',
     'if (sysutil_error)\n\t\t\t\t\t{\n'
     '\t\t\t\t\t\tneostation::savestate::current.error("PS3 system callbacks are still active. Wait for the system dialog to close, then retry.");'),
    ('''							Emu.after_kill_callback = nullptr;''', '''							Emu.after_kill_callback = nullptr;
							neostation::savestate::current.finish(false,
								"RPCS3 could not reach a savestate-safe point. Wait for cutscenes and game saving to finish, then retry.");'''),
    ('''			// Savestate thread
			named_thread emu_state_cap_thread''', '''			neostation::savestate::current.advance(neostation::savestate::phase::writing);
			// Savestate thread
			named_thread emu_state_cap_thread'''),
    ('''		// Log additional debug information - do not do it on the main thread due to the concern of halting UI events''', '''		neostation::savestate::current.record_write(savestate);

		// Log additional debug information - do not do it on the main thread due to the concern of halting UI events'''),
])

patch('rpcs3/ios/RPCS3IOS.cpp', 'NEOSTATION_SAVESTATE_STATUS_V1', [
    ('#include "IOSMemoryPressurePolicy.h"', '#include "IOSMemoryPressurePolicy.h"\n#include "NeoStationSavestateStatus.h" // NEOSTATION_SAVESTATE_STATUS_V1'),
    ('''    try
    {
        const u64 process_headroom''', '''    bool owns_operation = false;
    try
    {
        const u64 process_headroom'''),
    ('''        emit_log(4, "NeoStation requested an in-game savestate");
        Emu.CallFromMainThread([]()
        {
            Emu.after_kill_callback = []() { Emu.Restart(true, false); };''', '''        if (!neostation::savestate::current.begin())
        {
            set_error("A savestate is already being created or restored. Wait for it to finish.");
            return RPCS3_IOS_INVALID_STATE;
        }
        owns_operation = true;
        emit_log(4, "NeoStation requested an in-game savestate");
        Emu.CallFromMainThread([]()
        {
            if (Emu.GetStatus(false) != system_state::running)
            {
                neostation::savestate::current.finish(false, "The game stopped before savestate preparation.");
                return;
            }
            Emu.after_kill_callback = []()
            {
                if (!neostation::savestate::current.read().committed)
                {
                    Emu.SetContinuousMode(false);
                    neostation::savestate::current.finish(false, "Savestate writing failed; automatic reload was cancelled.");
                    return;
                }
                neostation::savestate::current.advance(neostation::savestate::phase::restarting);
                try
                {
                    const auto result = Emu.Restart(true, false);
                    if (result != game_boot_result::no_errors || Emu.GetStatus(false) == system_state::stopped)
                        neostation::savestate::current.finish(false, "The savestate was written, but RPCS3 could not restore it.");
                    else
                        neostation::savestate::current.finish(true);
                }
                catch (const std::exception& error)
                {
                    Emu.SetContinuousMode(false);
                    neostation::savestate::current.finish(false, error.what());
                }
            };'''),
    ('''    return RPCS3_IOS_INTERNAL_ERROR;
}

// NeoStation-private read-only enumeration.''', '''    if (owns_operation)
        neostation::savestate::current.finish(false, "RPCS3 could not dispatch savestate creation.");
    return RPCS3_IOS_INTERNAL_ERROR;
}

extern "C" RPCS3_IOS_EXPORT rpcs3_ios_status neostation_rpcs3_ios_get_savestate_status(
    uint32_t* phase, char* message, size_t capacity) noexcept
{
    if (!phase || !message || !capacity) return RPCS3_IOS_INVALID_ARGUMENT;
    try
    {
        const auto state = neostation::savestate::current.read();
        *phase = static_cast<uint32_t>(state.state);
        const size_t count = std::min(capacity - 1, state.message.size());
        std::memcpy(message, state.message.data(), count);
        message[count] = 0;
        return RPCS3_IOS_OK;
    }
    catch (...) { return RPCS3_IOS_INTERNAL_ERROR; }
}

// NeoStation-private read-only enumeration.'''),
])

# Refuse destructive concurrent operations while the asynchronous save owns Emu.
cpp = root / 'rpcs3/ios/RPCS3IOS.cpp'
text = cpp.read_text()
for name in ('rpcs3_ios_boot_game', 'rpcs3_ios_stop_emulation', 'rpcs3_ios_shutdown'):
    start = text.index(f'extern "C" rpcs3_ios_status {name}(')
    point = text.index('\tstd::lock_guard lock(g_api_mutex);', start)
    point += len('\tstd::lock_guard lock(g_api_mutex);')
    guard = '''
    // NEOSTATION_SAVE_EXCLUSIVE: asynchronous preparation still owns the game.
    if (neostation::savestate::current.read().active)
    {
        set_error("A savestate is in progress. Wait for creation and restoration to finish.");
        return RPCS3_IOS_INVALID_STATE;
    }'''
    if not text[point:].startswith(guard):
        text = text[:point] + guard + text[point:]
cpp.write_text(text)
exports = root / 'rpcs3/ios/RPCS3IOS.exports'
text = exports.read_text()
symbol = '_neostation_rpcs3_ios_get_savestate_status'
if symbol not in text.splitlines():
    exports.write_text(text.rstrip() + '\n' + symbol + '\n')
print('NeoStation native savestate stability patch: OK')
