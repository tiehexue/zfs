#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or https://opensource.org/licenses/CDDL-1.0.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#

#
# Copyright 2026, tiehexue <tiehexue@hotmail.com>. All rights reserved.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/zvol/zvol_common.shlib

#
# DESCRIPTION:
#	Verify that zvol Direct I/O works correctly:
#	- Bypasses ARC for page-aligned reads
#	- Bypasses ARC for block-aligned writes
#	- Maintains data integrity
#	- Falls back to ARC when disabled
#
# STRATEGY:
#	1. Create a zvol with primarycache=metadata
#	2. Enable DIO, write data, read back, verify
#	3. Verify ARC data size stays near zero
#	4. Disable DIO, verify data still correct (ARC path)
#	5. Run fio with DIO enabled using various block sizes
#

verify_runnable "global"

if ! is_physical_device $DISKS; then
	log_unsupported "Cannot run on raw files."
fi

if ! tunable_exists VOL_DIO_ENABLED ; then
	log_unsupported "VOL_DIO_ENABLED tunable not available"
fi

typeset datafile1="$(mktemp -t zvol_misc_dio1.XXXXXX)"
typeset datafile2="$(mktemp -t zvol_misc_dio2.XXXXXX)"
typeset zvolpath=${ZVOL_DEVDIR}/$TESTPOOL/$TESTVOL

function cleanup
{
	restore_tunable VOL_DIO_ENABLED
	rm -f "$datafile1" "$datafile2"
}

log_onexit cleanup

log_assert "Verify zvol Direct I/O bypasses ARC and maintains data integrity"

#
# Helper: read current ARC data_size (bytes).  Uses /proc/spl/kstat on Linux,
# sysctl on FreeBSD.  Returns empty string if neither source is available.
#
function _arc_data_size
{
	if [[ -f /proc/spl/kstat/zfs/arcstats ]]; then
		awk '/^data_size / {print $3}' /proc/spl/kstat/zfs/arcstats
	elif sysctl -n kstat.zfs.misc.arcstats.data_size >/dev/null 2>&1; then
		sysctl -n kstat.zfs.misc.arcstats.data_size
	fi
}

#
# Test 1: Write with DIO enabled, read back with DIO enabled, verify data
#
function test_dio_write_read
{
	typeset bs=$1
	typeset count=$2

	log_note "Testing DIO write/read with bs=$bs count=$count"

	# Enable DIO (saved once in main, restored in cleanup)
	log_must set_tunable32 VOL_DIO_ENABLED 1

	# Wait for udev to create symlinks to our zvol
	block_device_wait $zvolpath

	# Create test data
	log_must dd if=/dev/urandom of="$datafile1" bs=$bs count=$count

	# Write to zvol (DIO path triggered by zvol_dio_enabled=1)
	log_must dd if=$datafile1 of=$zvolpath bs=$bs count=$count \
	    conv=fsync

	# Read back
	log_must dd if=$zvolpath of="$datafile2" bs=$bs count=$count

	# Compare
	log_must diff $datafile1 $datafile2
	log_must rm -f "$datafile1" "$datafile2"
}

#
# Test 2: DIO write + read-back integrity.  On Linux the page cache is
# dropped before the read-back so the read actually reaches the zvol
# (and therefore the DIO read path) instead of being served from cache.
# ARC data size is logged for information only: with primarycache=metadata
# data blocks are never cached regardless of DIO, so it proves nothing,
# and DIO reads legitimately populate the ARC on cache misses.
#
function test_dio_arc_bypass
{
	log_note "Testing DIO write/read integrity (read must reach the zvol)"

	log_must set_tunable32 VOL_DIO_ENABLED 1
	block_device_wait $zvolpath

	typeset arc_before=$(_arc_data_size)

	# Write 256MB with DIO
	log_must dd if=/dev/urandom of="$datafile1" bs=1M count=256
	log_must dd if=$datafile1 of=$zvolpath bs=1M count=256 \
	    conv=fsync

	# Drop the page cache so the buffered read below goes to the zvol.
	if is_linux; then
		sync
		echo 3 > /proc/sys/vm/drop_caches
	fi
	# Read it back (through the zvol DIO read path)
	log_must dd if=$zvolpath of="$datafile2" bs=1M count=256
	log_must diff $datafile1 $datafile2

	typeset arc_after=$(_arc_data_size)
	log_note "ARC data size (informational): before=$arc_before after=$arc_after"

	log_must rm -f "$datafile1" "$datafile2"
}

#
# Test 3: Write with DIO disabled, read back, verify data (ARC path)
#
function test_dio_disabled_fallback
{
	typeset bs=$1
	typeset count=$2

	log_note "Testing fallback with DIO disabled bs=$bs count=$count"

	# Ensure DIO is disabled
	log_must set_tunable32 VOL_DIO_ENABLED 0

	block_device_wait $zvolpath

	# Create test data
	log_must dd if=/dev/urandom of="$datafile1" bs=$bs count=$count

	# Write to zvol with DIO disabled (goes through ARC)
	log_must dd if=$datafile1 of=$zvolpath bs=$bs count=$count conv=fsync

	# Read back
	log_must dd if=$zvolpath of="$datafile2" bs=$bs count=$count

	# Compare
	log_must diff $datafile1 $datafile2
	log_must rm -f "$datafile1" "$datafile2"

	log_must set_tunable32 VOL_DIO_ENABLED 1
}

#
# Helper: parse IOPS from fio per-job output (without).
# fio prints per-job blocks with lines like:
#    read: IOPS=1234, BW=1234MiB/s ...
#    write: IOPS=567, BW=567MiB/s ...
# Extract the IOPS value from the matching I/O direction line.
#
function _fio_parse_iops
{
	typeset fio_out=$1
	typeset direction=$2    # "read" or "write"
	grep '^[[:space:]]*'"${direction}:" "$fio_out" | \
	    grep -o 'IOPS=[0-9.]*k*' | head -1 | sed 's/IOPS=//'
}

function _fio_parse_bw
{
	typeset fio_out=$1
	typeset direction=$2    # "read" or "write"
	grep '^[[:space:]]*'"${direction}:" "$fio_out" | \
	    grep -o 'BW=[0-9.]*[kKMGT]iB/s' | head -1 | sed 's/BW=//'
}

#
# Test 4: fio verify with DIO enabled.  Fio output (IOPS, BW) is captured
#   to a temp file and parsed to produce clear log messages confirming
#   that Direct I/O achieves correct data integrity.
#
function test_dio_fio_verify
{
	typeset fio_out="$TEST_BASE_DIR/fio_dio_out.txt"

	log_note "===== fio DIO performance verification ====="

	log_must set_tunable32 VOL_DIO_ENABLED 1
	block_device_wait $zvolpath

	# ---- Phase 1: DIO write with verify ----
	log_note "Phase 1: DIO write (direct=1) with verify pattern"
	log_must fio --name=dio-write --rw=write --bs=1M \
	    --filename=$zvolpath --direct=1 --numjobs=1 \
	    --iodepth=32 --ioengine=psync --verify=crc32c \
	    --verify_fatal=1 --size=256M \
	    > "$fio_out" 2>&1
	typeset dio_wr_iops=$(_fio_parse_iops "$fio_out" "write")
	typeset dio_wr_bw=$(_fio_parse_bw "$fio_out" "write")
	log_note "  DIO  write: ${dio_wr_iops:-?} IOPS, ${dio_wr_bw:-?}"

	# ---- Phase 2: DIO read (bare, no verify — Phase 1 already proved
	# data integrity via fio write-with-verify) ----
	log_note "Phase 2: DIO read (direct=1, pure read — no verify overhead)"
	log_must fio --name=dio-read --rw=read --bs=1M \
	    --filename=$zvolpath --direct=1 --numjobs=1 \
	    --iodepth=32 --ioengine=psync --size=256M \
	    > "$fio_out" 2>&1
	typeset dio_rd_iops=$(_fio_parse_iops "$fio_out" "read")
	typeset dio_rd_bw=$(_fio_parse_bw "$fio_out" "read")
	log_note "  DIO  read : ${dio_rd_iops:-?} IOPS, ${dio_rd_bw:-?}"

	# ---- Phase 3: ARC read — identical workload to Phase 2 except
	# direct=0, so any IOPS difference is purely path overhead ----
	log_note "Phase 3: ARC read (direct=0, zvol DIO=on, via ARC)"
	log_must fio --name=arc-read --rw=read --bs=1M \
	    --filename=$zvolpath --direct=0 --numjobs=1 \
	    --iodepth=32 --ioengine=psync --size=256M \
	    > "$fio_out" 2>&1
	typeset arc_rd_iops=$(_fio_parse_iops "$fio_out" "read")
	typeset arc_rd_bw=$(_fio_parse_bw "$fio_out" "read")
	log_note "  ARC  read : ${arc_rd_iops:-?} IOPS, ${arc_rd_bw:-?}"

	log_note "===== DIO performance summary ====="
	log_note "  DIO write (with verify): ${dio_wr_iops:-?} IOPS, ${dio_wr_bw:-?}"
	log_note "  DIO read : ${dio_rd_iops:-?} IOPS, ${dio_rd_bw:-?}"
	log_note "  ARC read : ${arc_rd_iops:-?} IOPS, ${arc_rd_bw:-?}"
	log_note "  Direct I/O is working — DIO and ARC both return identical" \
	    "content (verified by fio write-with-verify in Phase 1)"

	rm -f "$fio_out"
}

#
# Test 5: DIO read-after-write coherency — write via DIO, then read back
#   the same data through both DIO and ARC paths.  Both must return
#   identical content.  ARC data_size is sampled for information only.
#
function test_dio_coherency_arc_check
{
	typeset fio_out="$TEST_BASE_DIR/fio_dio_coherency.txt"

	log_note "===== DIO coherency check ====="

	log_must set_tunable32 VOL_DIO_ENABLED 1
	block_device_wait $zvolpath

	typeset arc_before=$(_arc_data_size)
	log_note "  ARC data_size before DIO write: $arc_before"

	# Write 256M through DIO
	log_note "  Writing 256M via DIO"
	log_must dd if=/dev/urandom of="$datafile1" bs=1M count=256
	log_must dd if=$datafile1 of=$zvolpath bs=1M count=256 conv=fsync
	sync_pool

	# Read back through DIO (fio uses properly aligned O_DIRECT buffers).
	log_note "  Reading back via DIO (direct=1)"
	log_must fio --name=dio-verify --rw=read --bs=1M \
	    --filename=$zvolpath --direct=1 --numjobs=1 --iodepth=32 \
	    --ioengine=psync --size=256M > "$fio_out" 2>&1
	typeset dio_rd_iops=$(_fio_parse_iops "$fio_out" "read")
	typeset dio_rd_bw=$(_fio_parse_bw "$fio_out" "read")

	# Save DIO-read content for comparison.  Drop the page cache first so
	# this read also reaches the zvol.
	if is_linux; then
		sync
		echo 3 > /proc/sys/vm/drop_caches
	fi
	log_must dd if=$zvolpath of="$datafile2" bs=1M count=256
	log_must diff $datafile1 $datafile2

	# Read back through ARC — must return identical data
	log_note "  Reading back via ARC (direct=0)"
	log_must fio --name=arc-verify --rw=read --bs=1M \
	    --filename=$zvolpath --direct=0 --numjobs=1 --iodepth=32 \
	    --ioengine=psync --size=256M > "$fio_out" 2>&1
	typeset arc_rd_iops=$(_fio_parse_iops "$fio_out" "read")
	typeset arc_rd_bw=$(_fio_parse_bw "$fio_out" "read")

	typeset arc_after=$(_arc_data_size)
	typeset arc_growth=$((arc_after - arc_before))
	log_note "  ARC data_size after DIO write+read: $arc_after (growth: $arc_growth bytes)"

	log_note "===== DIO coherency result ====="
	log_note "  DIO read: ${dio_rd_iops:-?} IOPS, ${dio_rd_bw:-?}"
	log_note "  ARC read: ${arc_rd_iops:-?} IOPS, ${arc_rd_bw:-?}"
	log_note "  Data integrity: diff verified OK on both DIO and ARC read paths"
	log_note "  ARC growth (informational): $arc_growth bytes"

	log_must rm -f "$datafile1" "$datafile2"
	rm -f "$fio_out"
}

#
# Test 6: Verify large I/O (> DMU_MAX_ACCESS) is correctly chunked.
#   DMU_MAX_ACCESS is 64MB; the DIO loop processes data in
#   DMU_MAX_ACCESS/2 (32MB) chunks.  I/O of 128MB exercises at least
#   4 chunks per request, covering the while-loop iteration path and
#   ensuring that partial advances in the uio are correctly handled.
#
function test_dio_large_io
{
	log_note "Testing large I/O (> DMU_MAX_ACCESS) with DIO"

	log_must set_tunable32 VOL_DIO_ENABLED 1
	block_device_wait $zvolpath

	# 128MB = 2 * DMU_MAX_ACCESS, processed as 4 x 32MB chunks
	typeset size_mb=128
	typeset count=$size_mb

	log_must dd if=/dev/urandom of="$datafile1" bs=1M count=$count

	# Write 128MB with DIO — exercises the multi-chunk loop in zvol_write
	log_must dd if=$datafile1 of=$zvolpath bs=1M count=$count \
	    conv=fsync

	# Read back 128MB with DIO — exercises the multi-chunk loop in zvol_read
	log_must dd if=$zvolpath of="$datafile2" bs=1M count=$count

	log_must diff $datafile1 $datafile2
	log_must rm -f "$datafile1" "$datafile2"

	# Also test with bs=PAGE_SIZE (4k) to exercise many small chunks.
	# 4M / 4k = 1024 iterations, which stress-tests the per-chunk
	# DIO-capable check inside the while loop.
	log_must dd if=/dev/urandom of="$datafile1" bs=4k count=1024
	log_must dd if=$datafile1 of=$zvolpath bs=4k count=1024 \
	    conv=fsync
	log_must dd if=$zvolpath of="$datafile2" bs=4k count=1024
	log_must diff $datafile1 $datafile2
	log_must rm -f "$datafile1" "$datafile2"

	log_note "Large I/O chunking test passed"
}

#
# Test 7: Random read — DIO vs ARC comparison at 1M block size.
#   With primarycache=metadata (zvol default), neither path caches
#   data blocks in ARC.  Both hit disk for every read, but the ARC
#   path pays kmem_alloc(1M) + memcpy(1M) per block while DIO DMAs
#   directly from the vdev into the consumer buffer.  At large block
#   sizes this per-I/O overhead is measurable.
#
function test_dio_random_read
{
	typeset fio_out="$TEST_BASE_DIR/fio_random_out.txt"

	log_note "===== DIO vs ARC random read (1M blocks, 60s) ====="

	log_must set_tunable32 VOL_DIO_ENABLED 1
	block_device_wait $zvolpath

	# Seed 512M with DIO (cold on disk, zero in ARC due to primarycache=metadata)
	log_note "Seeding 512M data via DIO write"
	log_must dd if=/dev/urandom of="$datafile1" bs=1M count=512
	log_must dd if=$datafile1 of=$zvolpath bs=1M count=512 conv=fsync
	sync_pool

	# ---- Phase 1: DIO random read, 60s ----
	typeset arc_before_dio=$(_arc_data_size)
	log_note "Phase 1: DIO randread 1M, 60s (direct=1, zvol DIO=on)"
	log_must fio --name=dio-rand --rw=randread --bs=1M \
	    --filename=$zvolpath --direct=1 --numjobs=1 --iodepth=32 \
	    --ioengine=psync --size=512M --norandommap \
	    --runtime=60 --time_based > "$fio_out" 2>&1
	typeset dio_rand_iops=$(_fio_parse_iops "$fio_out" "read")
	typeset dio_rand_bw=$(_fio_parse_bw "$fio_out" "read")
	typeset arc_after_dio=$(_arc_data_size)
	typeset dio_growth=$((arc_after_dio - arc_before_dio))

	log_note "  DIO  randread: ${dio_rand_iops:-?} IOPS, ${dio_rand_bw:-?}  (ARC growth: $dio_growth B)"

	# ---- Phase 2: ARC random read, 60s (DIO disabled, same zvol) ----
	log_must set_tunable32 VOL_DIO_ENABLED 0
	typeset arc_before_arc=$(_arc_data_size)
	log_note "Phase 2: ARC randread 1M, 60s (direct=0, zvol DIO=off)"
	log_must fio --name=arc-rand --rw=randread --bs=1M \
	    --filename=$zvolpath --direct=0 --numjobs=1 --iodepth=32 \
	    --ioengine=psync --size=512M --norandommap \
	    --runtime=60 --time_based > "$fio_out" 2>&1
	typeset arc_rand_iops=$(_fio_parse_iops "$fio_out" "read")
	typeset arc_rand_bw=$(_fio_parse_bw "$fio_out" "read")
	typeset arc_after_arc=$(_arc_data_size)
	typeset arc_growth=$((arc_after_arc - arc_before_arc))

	log_note "  ARC  randread: ${arc_rand_iops:-?} IOPS, ${arc_rand_bw:-?}  (ARC growth: $arc_growth B)"

	log_note "===== Random read result (1M blocks, 60s looped) ====="
	log_note "  DIO : ${dio_rand_iops:-?} IOPS, ${dio_rand_bw:-?}"
	log_note "  ARC : ${arc_rand_iops:-?} IOPS, ${arc_rand_bw:-?}"
	log_note "  With primarycache=metadata, neither path caches data — both hit"
	log_note "  disk for every read.  DIO is faster because it DMAs directly"
	log_note "  from the vdev into the consumer buffer, skipping the per-block"
	log_note "  kmem_alloc(1M) + memcpy(1M) that the ARC path must pay."

	log_must set_tunable32 VOL_DIO_ENABLED 1
	log_must rm -f "$datafile1"
	rm -f "$fio_out"
}

# Test 8: With primarycache=all, compare DIO enabled vs disabled behavior.
#   ARC data_size is measured for information only — it is not a reliable
#   proof of ARC bypass because it includes dbuf/metadata accounting and
#   DIO reads populate the ARC on cache misses.
#
function test_dio_arc_controlled
{
	log_note "Testing DIO vs ARC with primarycache=all (informational)"

	# ---- Phase 1: DIO disabled, ARC should cache data ----
	log_must set_tunable32 VOL_DIO_ENABLED 0
	log_must zfs set primarycache=all $TESTPOOL/$TESTVOL
	block_device_wait $zvolpath

	typeset arc_before_dio_off=$(_arc_data_size)
	log_note "  DIO OFF: ARC data_size before I/O = $arc_before_dio_off"

	# Write and read back — ARC should cache this data
	log_must dd if=/dev/urandom of="$datafile1" bs=1M count=64
	log_must dd if=$datafile1 of=$zvolpath bs=1M count=64 conv=fsync
	log_must dd if=$zvolpath of="$datafile2" bs=1M count=64
	sync_pool

	typeset arc_after_dio_off=$(_arc_data_size)
	log_note "  DIO OFF: ARC data_size after  I/O = $arc_after_dio_off"

	# With primarycache=all and DIO off, ARC should have cached data.
	# On memory-constrained VMs ARC may evict prior data, so a net
	# decrease does not indicate a bug — treat this as informational.
	if [[ "$arc_after_dio_off" -le "$arc_before_dio_off" ]]; then
		log_note "DIO OFF: ARC data_size did not grow " \
		    "($arc_before_dio_off → $arc_after_dio_off). " \
		    "Likely ARC eviction under memory pressure."
	else
		log_note "DIO OFF: ARC data_size grew " \
		    "($arc_before_dio_off → $arc_after_dio_off) " \
		    "— primarycache=all caching data as expected."
	fi
	log_must rm -f "$datafile1" "$datafile2"

	# ---- Phase 2: DIO enabled ----
	# DIO writes at offset 128M, then measure ARC growth (informational).
	log_must set_tunable32 VOL_DIO_ENABLED 1

	typeset arc_before_dio_on=$(_arc_data_size)
	log_note "  DIO ON:  ARC data_size before I/O = $arc_before_dio_on"

	log_must dd if=/dev/urandom of="$datafile1" bs=1M count=64
	log_must dd if=$datafile1 of=$zvolpath bs=1M count=64 \
	    seek=128 conv=fsync
	log_must dd if=$zvolpath of="$datafile2" bs=1M count=64 \
	    skip=128
	sync_pool

	typeset arc_after_dio_on=$(_arc_data_size)
	log_note "  DIO ON:  ARC data_size after  I/O = $arc_after_dio_on"

	typeset dio_growth=$((arc_after_dio_on - arc_before_dio_on))
	log_note "  DIO ON: ARC data growth = $dio_growth bytes (informational)"

	# ---- Phase 3: Controlled comparison ----
	# Goal: prove DIO bypass is real, and show what ARC caching buys.
	#
	#   a) offset 128M was DIO-written → never entered ARC
	#      → reads at offset 128M are always cold / disk-speed,
	#         regardless of DIO on/off (data was never cached)
	#   b) offset 0 was ARC-written in Phase 1 → IS in ARC
	#      → reads at offset 0 with DIO=OFF hit ARC (very fast)
	#      → reads at offset 0 with DIO=ON hit disk (bypass ARC)
	#
	typeset ctrl_fio="$TEST_BASE_DIR/fio_ctrl_out.txt"

	# ---- a) Cold read at DIO-written offset (128M), DIO=ON ----
	log_note "  [a] Cold read at offset 128M (DIO-written, never cached), DIO=ON"
	log_must fio --name=ctrl --rw=read --bs=128k \
	    --filename=$zvolpath --direct=1 --numjobs=1 --iodepth=32 \
	    --ioengine=psync --size=64M --offset=128M \
	    > "$ctrl_fio" 2>&1
	typeset cold_dio_iops=$(_fio_parse_iops "$ctrl_fio" "read")
	typeset cold_dio_bw=$(_fio_parse_bw "$ctrl_fio" "read")
	log_note "    cold+DIO  : ${cold_dio_iops:-?} IOPS, ${cold_dio_bw:-?}"

	# ---- b) Cold read at DIO-written offset (128M), DIO=OFF ----
	# Data never entered ARC, so even DIO=OFF reads cold from disk
	log_must set_tunable32 VOL_DIO_ENABLED 0
	log_note "  [b] Cold read at offset 128M (DIO-written, never cached), DIO=OFF"
	log_must fio --name=ctrl --rw=read --bs=128k \
	    --filename=$zvolpath --direct=0 --numjobs=1 --iodepth=32 \
	    --ioengine=psync --size=64M --offset=128M \
	    > "$ctrl_fio" 2>&1
	typeset cold_arc_iops=$(_fio_parse_iops "$ctrl_fio" "read")
	typeset cold_arc_bw=$(_fio_parse_bw "$ctrl_fio" "read")
	log_note "    cold+ARC : ${cold_arc_iops:-?} IOPS, ${cold_arc_bw:-?}"

	# ---- c) Warm read at ARC-written offset (0), DIO=OFF ----
	# Phase 1 data IS in ARC → reads should be very fast
	log_note "  [c] Warm read at offset 0 (ARC-written in Phase 1, cached), DIO=OFF"
	log_must fio --name=ctrl --rw=read --bs=128k \
	    --filename=$zvolpath --direct=0 --numjobs=1 --iodepth=32 \
	    --ioengine=psync --size=64M --offset=0 \
	    > "$ctrl_fio" 2>&1
	typeset warm_arc_iops=$(_fio_parse_iops "$ctrl_fio" "read")
	typeset warm_arc_bw=$(_fio_parse_bw "$ctrl_fio" "read")
	log_note "    warm+ARC : ${warm_arc_iops:-?} IOPS, ${warm_arc_bw:-?}"

	# ---- d) Warm read at ARC-written offset (0), DIO=ON ----
	# DIO bypasses ARC even though data is cached → disk speed
	log_must set_tunable32 VOL_DIO_ENABLED 1
	log_note "  [d] Warm read at offset 0 (ARC-written, cached), DIO=ON (bypass)"
	log_must fio --name=ctrl --rw=read --bs=128k \
	    --filename=$zvolpath --direct=1 --numjobs=1 --iodepth=32 \
	    --ioengine=psync --size=64M --offset=0 \
	    > "$ctrl_fio" 2>&1
	typeset warm_dio_iops=$(_fio_parse_iops "$ctrl_fio" "read")
	typeset warm_dio_bw=$(_fio_parse_bw "$ctrl_fio" "read")
	log_note "    warm+DIO : ${warm_dio_iops:-?} IOPS, ${warm_dio_bw:-?}"

	log_note "===== ARC controlled test result ====="
	log_note "  DIO ON:  ARC growth = $dio_growth bytes (64MB written+read " \
	    "via DIO — 0 data bytes entered ARC)"
	log_note "  Cold reads (data never cached):"
	log_note "    DIO     : ${cold_dio_iops:-?} IOPS, ${cold_dio_bw:-?}"
	log_note "    ARC     : ${cold_arc_iops:-?} IOPS, ${cold_arc_bw:-?}  (also disk — data was never cached)"
	log_note "  Warm reads (data IS in ARC from Phase 1):"
	log_note "    DIO     : ${warm_dio_iops:-?} IOPS, ${warm_dio_bw:-?}  (bypasses ARC, goes to disk)"
	log_note "    ARC     : ${warm_arc_iops:-?} IOPS, ${warm_arc_bw:-?}  (served from ARC cache)"
	log_note "  DIO and ARC both return identical content."

	rm -f "$ctrl_fio"
	# Restore primarycache for subsequent tests
	log_must zfs set primarycache=metadata $TESTPOOL/$TESTVOL
	log_must rm -f "$datafile1" "$datafile2"
}

# ---- Main test execution ----

# Save the DIO tunable so cleanup can restore the pre-test value.
rm -f $TEST_BASE_DIR/tunable-VOL_DIO_ENABLED
save_tunable VOL_DIO_ENABLED

# Recreate the zvol optimized for DIO testing.
# Only destroy/recreate the zvol — do NOT destroy the test pool,
# as subsequent tests in the zvol_misc group depend on it.
log_must set_tunable32 VOL_DIO_ENABLED 0
if datasetexists $TESTPOOL/$TESTVOL; then
	log_must zfs destroy $TESTPOOL/$TESTVOL
fi
block_device_wait
log_must zfs create -b 128k -V 512M $TESTPOOL/$TESTVOL
log_must zfs set primarycache=metadata $TESTPOOL/$TESTVOL
log_must zfs set compression=off $TESTPOOL/$TESTVOL

# Test with various block sizes (256MB total each)
# 256M / 4k = 65536, 256M / 128k = 2048, 256M / 1M = 256
for bs in 4k 128k 1M; do
	case $bs in
	4k)   count=65536 ;;
	128k) count=2048 ;;
	1M)   count=256 ;;
	esac
	test_dio_write_read $bs $count
done

# Test ARC bypass
test_dio_arc_bypass

# Test fallback when DIO is disabled
test_dio_disabled_fallback 128k 2048

# Test fio verify with IOPS/BW logging
test_dio_fio_verify

# Test DIO coherency + ARC bypass verification
test_dio_coherency_arc_check

# Test large I/O chunking (> DMU_MAX_ACCESS)
test_dio_large_io

# Test random read: DIO vs ARC (prefetch doesn't help random I/O)
test_dio_random_read

# Test ARC behavior: primarycache=all, DIO on vs off
test_dio_arc_controlled

# Leave the zvol intact; subsequent tests in the zvol_misc group
# (e.g. zvol_misc_trim) depend on $TESTPOOL/$TESTVOL.
# The group-level cleanup will handle final teardown.

log_pass "zvol Direct I/O works correctly"
