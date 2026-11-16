"""Check actual MSF7 compiler PDB identities against COFF type-server records."""
import argparse
import pathlib
import struct
import uuid


def pdb_identity(path):
    data = pathlib.Path(path).read_bytes()
    assert data[:32] == b"Microsoft C/C++ MSF 7.00\r\n\x1aDS\0\0\0", path
    block_size, _, blocks, size, _, block_map = struct.unpack_from("<6I", data, 32)
    assert blocks * block_size == len(data), (path, "truncated MSF")
    count = (size + block_size - 1) // block_size
    directory_blocks = struct.unpack_from(f"<{count}I", data, block_map * block_size)
    directory = b"".join(data[b * block_size:(b + 1) * block_size]
                         for b in directory_blocks)[:size]
    streams, = struct.unpack_from("<I", directory)
    sizes = struct.unpack_from(f"<{streams}I", directory, 4)
    offset = 4 + 4 * streams
    info = None
    for index, stream_size in enumerate(sizes):
        n = 0 if stream_size == 0xffffffff else (stream_size + block_size - 1) // block_size
        stream_blocks = struct.unpack_from(f"<{n}I", directory, offset)
        offset += 4 * n
        assert all(b < blocks for b in stream_blocks), (path, "invalid stream block")
        if index == 1:
            info = b"".join(data[b * block_size:(b + 1) * block_size]
                            for b in stream_blocks)[:stream_size]
    _, _, age = struct.unpack_from("<3I", info)
    return info[12:28], age


def object_identity(path):
    data = pathlib.Path(path).read_bytes()
    machine, count = struct.unpack_from("<HH", data)
    assert machine == 0x8664, (path, "not AMD64 COFF")
    optional_size, = struct.unpack_from("<H", data, 16)
    for i in range(count):
        offset = 20 + optional_size + 40 * i
        name = data[offset:offset + 8].rstrip(b"\0")
        size, start = struct.unpack_from("<II", data, offset + 16)
        if name == b".debug$T":
            section = data[start:start + size]
            assert struct.unpack_from("<I", section)[0] == 4
            offset = 4
            while offset + 4 <= len(section):
                length, kind = struct.unpack_from("<HH", section, offset)
                if kind == 0x1515:  # LF_TYPESERVER2
                    guid = section[offset + 4:offset + 20]
                    age, = struct.unpack_from("<I", section, offset + 20)
                    name = section[offset + 24:offset + 2 + length].split(b"\0")[0]
                    return guid, age, name.decode("utf-8")
                offset += 2 + length
    raise AssertionError((path, "missing LF_TYPESERVER2"))


def pe_identity(path):
    data = pathlib.Path(path).read_bytes()
    assert data[:2] == b"MZ", path
    pe, = struct.unpack_from("<I", data, 60)
    assert data[pe:pe + 4] == b"PE\0\0", path
    machine, count = struct.unpack_from("<HH", data, pe + 4)
    assert machine == 0x8664, path
    optional_size, = struct.unpack_from("<H", data, pe + 20)
    optional = pe + 24
    assert struct.unpack_from("<H", data, optional)[0] == 0x20b
    debug_rva, debug_size = struct.unpack_from("<II", data, optional + 112 + 6 * 8)
    sections = optional + optional_size
    for i in range(count):
        offset = sections + i * 40
        virtual_size, rva, size, raw = struct.unpack_from("<4I", data, offset + 8)
        if rva <= debug_rva < rva + max(size, virtual_size):
            debug = raw + debug_rva - rva
            for entry in range(debug, debug + debug_size, 28):
                kind, _, _, start = struct.unpack_from("<4I", data, entry + 12)
                if kind == 2 and data[start:start + 4] == b"RSDS":
                    age, = struct.unpack_from("<I", data, start + 20)
                    return data[start + 4:start + 20], age
    raise AssertionError((path, "missing PE CodeView RSDS"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("pdb", nargs="?")
    parser.add_argument("objects", nargs="*")
    parser.add_argument("--pe")
    parser.add_argument("--objects-directory")
    args = parser.parse_args()
    if args.objects_directory:
        objects = sorted(pathlib.Path(args.objects_directory).glob("*.obj"))
        assert objects, "no COFF objects in directory"
        for path in objects:
            pdb = path.with_suffix(".pdb")
            if not pdb.exists():
                pdb = pathlib.Path(str(path) + ".pdb")
            guid, age = pdb_identity(pdb)
            obj_guid, obj_age, name = object_identity(path)
            assert obj_guid == guid and obj_age <= age, (path, "PDB identity mismatch")
            assert pathlib.Path(name).resolve() == pdb.resolve(), (path, name)
        print(f"PASS MSF7/COFF independent compiler PDBs objects={len(objects)}")
        raise SystemExit(0)
    if args.pdb is None:
        parser.error("pdb is required unless --objects-directory is specified")
    guid, age = pdb_identity(args.pdb)
    for path in args.objects:
        obj_guid, obj_age, name = object_identity(path)
        assert obj_guid == guid, (path, "PDB GUID mismatch")
        assert obj_age <= age, (path, "PDB age too old")
        assert pathlib.Path(name).resolve() == pathlib.Path(args.pdb).resolve(), (path, name)
    if args.pe:
        assert pe_identity(args.pe) == (guid, age), (args.pe, "PE/PDB identity mismatch")
    print(f"PASS MSF7/COFF {uuid.UUID(bytes_le=guid)} age={age} objects={len(args.objects)}")
