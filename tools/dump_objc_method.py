import sys
import struct
import ktool
from ktool.objc import objc2_class, objc2_class_ro, objc2_meth_list
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

binary, class_name, wanted = sys.argv[1:4]
with open(binary, "rb") as source:
    image = ktool.load_image(source, slice_index=1)
    objc = ktool.load_objc_metadata(image)
    cls = next(item for item in objc.classlist if item.name == class_name)
    class_data = objc.read_struct(cls.loc, objc2_class, vm=True)
    ro_location = class_data.info >> 2 << 2
    ro = objc.read_struct(ro_location, objc2_class_ro, vm=True)
    header = objc.read_struct(ro.base_meths, objc2_meth_list, vm=True)
    print("HEADER", header, "entrysize", header.entrysize, "count", header.count, file=sys.stderr)
    entry = ro.base_meths + objc2_meth_list.size(image.ptr_size)
    for _ in range(header.count):
        if header.entrysize == 24:
            selector_ptr = objc.read_ptr(entry, vm=True)
            selector = objc.read_cstr(selector_ptr, 0, vm=True)
            imp = objc.read_ptr(entry + 16, vm=True)
        else:
            name_rel = struct.unpack("<i", image.read_bytearray(entry, 4, vm=True))[0]
            imp_rel = struct.unpack("<i", image.read_bytearray(entry + 8, 4, vm=True))[0]
            try:
                selector_ptr = objc.read_ptr(entry + name_rel, vm=True)
                selector = objc.read_cstr(selector_ptr, 0, vm=True)
            except Exception:
                selector = objc.read_cstr(entry + name_rel, 0, vm=True)
            imp = entry + 8 + imp_rel
        print("SELECTOR", selector, file=sys.stderr)
        if selector == wanted:
            code = bytes(image.read_bytearray(imp, 4096, vm=True))
            dis = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
            for instruction in dis.disasm(code, imp):
                print(f"{instruction.address:#x}:\t{instruction.mnemonic}\t{instruction.op_str}")
                if instruction.address >= imp + 0xd00:
                    break
            break
        entry += header.entrysize
