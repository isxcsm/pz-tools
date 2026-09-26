package pztools.extensions.seamless.b4220;

import java.lang.classfile.*;
import java.lang.classfile.instruction.*;
import java.util.*;

/** Splits only verified, closed-resource regions of the private root. Original catch paths remain intact. */
final class SaveStageFilter {
    static final int CELL = 4, VEHICLES = 12, COUNT = 13;
    private SaveStageFilter() { }
    static CodeTransform stage(CodeModel body, int selected) {
        if (selected < 0 || selected >= COUNT) throw new IllegalArgumentException("Save stage");
        List<CodeElement> code = body.elementList();
        int[] starts = new int[COUNT + 1];
        starts[0] = fileStart(code, "map_ver.bin");
        starts[1] = fileStart(code, "map_sand.bin");
        starts[2] = field(code, "zombie/iso/worldgen/WorldGenParams", "INSTANCE", starts[1]);
        starts[3] = call(code, "java/lang/Thread", "currentThread", starts[2]);
        starts[4] = fileStart(code, "map.bin");
        starts[5] = call(code, "zombie/characters/animals/AnimalPopulationManager", "getInstance", starts[4]);
        starts[6] = field(code, "zombie/MapCollisionData", "instance", starts[5]);
        starts[7] = call(code, "zombie/radio/ZomboidRadio", "getInstance", starts[6]);
        starts[8] = field(code, "zombie/world/moddata/GlobalModData", "instance", starts[7]);
        starts[9] = call(code, "zombie/inventory/types/MapItem", "SaveWorldMap", starts[8]);
        starts[10] = call(code, "zombie/iso/FishSchoolManager", "getInstance", starts[9]);
        starts[11] = call(code, "zombie/entity/GameEntityManager", "Save", starts[10]);
        starts[12] = field(code, "zombie/network/GameClient", "client", starts[11]);
        starts[13] = nextInstruction(code, call(code, "zombie/vehicles/VirtualVehicleManager", "save", starts[12]) + 1);
        for (int i = 1; i < starts.length; i++) if (starts[i] <= starts[i - 1]) throw new IllegalArgumentException("Save regions changed");
        return CodeTransform.ofStateful(() -> new CodeTransform() {
            int index, region;
            Label[] labels;
            public void atStart(CodeBuilder builder) {
                labels = new Label[starts.length];
                Arrays.setAll(labels, ignored -> builder.newLabel());
            }
            public void accept(CodeBuilder builder, CodeElement element) {
                if (region < starts.length && index == starts[region]) {
                    builder.labelBinding(labels[region]);
                    if (region < COUNT && (region != selected || region == 3)) builder.goto_(labels[region + 1]);
                    region++;
                }
                builder.with(element); index++;
            }
            public void atEnd(CodeBuilder builder) {
                if (region != starts.length) throw new IllegalArgumentException("Incomplete save region map");
            }
        });
    }
    private static int fileStart(List<CodeElement> code, String name) {
        for (int i = 1; i < code.size(); i++) if (code.get(i) instanceof ConstantInstruction c && name.equals(c.constantValue())) {
            int previous = i - 1;
            while (previous >= 0 && !(code.get(previous) instanceof Instruction)) previous--;
            if (previous >= 0 && code.get(previous) instanceof FieldInstruction f
                    && f.owner().asInternalName().equals("zombie/ZomboidFileSystem") && f.name().equalsString("instance")) return previous;
            throw new IllegalArgumentException("File region starts with a live operand stack");
        }
        throw new IllegalArgumentException("Missing save file region: " + name);
    }
    private static int field(List<CodeElement> code, String owner, String name, int after) {
        for (int i = after + 1; i < code.size(); i++) if (code.get(i) instanceof FieldInstruction f
                && f.opcode() == Opcode.GETSTATIC && f.owner().asInternalName().equals(owner) && f.name().equalsString(name)) return i;
        throw new IllegalArgumentException("Missing save field boundary: " + owner + "." + name);
    }
    private static int call(List<CodeElement> code, String owner, String name, int after) {
        for (int i = after + 1; i < code.size(); i++) if (code.get(i) instanceof InvokeInstruction c
                && c.owner().asInternalName().equals(owner) && c.name().equalsString(name)) return i;
        throw new IllegalArgumentException("Missing save call boundary: " + owner + "." + name);
    }
    private static int nextInstruction(List<CodeElement> code, int start) {
        for (int i = start; i < code.size(); i++) if (code.get(i) instanceof Instruction) return i;
        throw new IllegalArgumentException("Missing closed-region end");
    }
}
