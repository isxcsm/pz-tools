package pztools.extensions.vehicle;

import java.lang.classfile.*;
import java.lang.classfile.instruction.*;
import java.util.*;

/** Structural boundaries for the code we bypass; unrelated controller code is not pinned here. */
final class VehiclePatchContract {
    private static final String TARGET=VehicleBytecode.TARGET;
    // Braking remains original code, but DIRECTION_HOLD depends on its resolved-mode gate.
    private static final Map<String,String> GUARDED_CONTROLS=Map.of(
        "control_NoControl","NoControl", "control_ForwardNew","Forward",
        "control_Reverse","Reverse", "control_Braking","Braking");
    private static final Map<String,String> FIELDS=Map.of(
        "vehicleSteering","F", "speed","F", "clientControls","L"+TARGET+"$ClientControls;",
        "vehicleObject","Lzombie/vehicles/BaseVehicle;", "isGas","Z", "isGasR","Z", "isBreak","Z");
    private static final List<String> CALL_ORDER=List.of(
        TARGET+".control_NoControl()V", TARGET+".control_Reverse(F)V", TARGET+".control_ForwardNew(F)V",
        TARGET+".updateBackSignal()V", TARGET+".control_Braking()V", TARGET+".updateBrakeLights()V",
        TARGET+".updateRammingSound(F)V", "zombie/scripting/objects/VehicleScript.getSteeringClamp(F)F",
        "zombie/vehicles/BaseVehicle.isDoingOffroad()Z", "zombie/vehicles/BaseVehicle.setCurrentSteering(F)V",
        "zombie/core/physics/Bullet.controlVehicle(IFFF)V", "zombie/core/physics/Bullet.controlVehicle(IFFF)V");
    private record Region(String name,int start,int end) { }

    private VehiclePatchContract() { }

    static void validate(ClassModel model,CodeModel code,List<Instruction> instructions,
            int entryIndex,int modeSlot,int speedSlot,int steeringStart,int steeringEnd) {
        validateMembers(model);
        validateCallOrder(instructions);
        int size=instructions.size();
        if(entryIndex<0 || entryIndex>=steeringStart || steeringStart<0 || steeringEnd<=steeringStart
                || steeringEnd>=size || modeSlot<=0 || speedSlot<=0 || modeSlot==speedSlot)
            throw rejected("patch-boundaries");

        var positions=new HashMap<Label,Integer>();
        var catches=new ArrayList<ExceptionCatch>();
        int position=0;
        for(var element:code) {
            if(element instanceof LabelTarget target) {
                Integer previous=positions.put(target.label(),position);
                if(previous!=null && previous!=position) throw rejected("duplicate-label");
            }
            if(element instanceof ExceptionCatch handler) catches.add(handler);
            // Match the caller's semantic instruction indices while leaving source NOPs untouched.
            if(element instanceof Instruction instruction && instruction.opcode()!=Opcode.NOP) position++;
        }
        if(position!=size) throw rejected("instruction-index");

        int offroadCall=-1;
        Region offroad=null;
        for(int i=0;i<size;i++) {
            if(instructions.get(i) instanceof InvokeInstruction call
                    && call.owner().asInternalName().equals("zombie/vehicles/BaseVehicle")
                    && call.name().equalsString("isDoingOffroad") && call.type().equalsString("()Z")) {
                if(offroadCall>=0 || call.opcode()!=Opcode.INVOKEVIRTUAL) throw rejected("offroad-call");
                int next=i+1;
                while(next<size && instructions.get(next).opcode()==Opcode.NOP) next++;
                if(next>=size || !(instructions.get(next) instanceof BranchInstruction branch)
                        || branch.opcode()!=Opcode.IFEQ) throw rejected("offroad-condition");
                int end=position(positions,branch.target(),size,false);
                if(end<=next+1) throw rejected("offroad-boundaries");
                offroadCall=i;
                offroad=new Region("offroad",next+1,end);
            }
        }
        if(offroad==null || offroad.start()<steeringEnd && offroad.end()>steeringStart)
            throw rejected("offroad-boundaries");
        var regions=List.of(new Region("steering",steeringStart,steeringEnd),offroad);

        var edges=new ArrayList<List<Integer>>(size);
        for(int i=0;i<size;i++) edges.add(new ArrayList<>());
        var protectedCalls=new ArrayList<Integer>();
        var guardStarts=new HashMap<Integer,Integer>();
        int brakingCall=-1,backSignalCall=-1;
        for(int i=0;i<size;i++) {
            Instruction instruction=instructions.get(i);
            Opcode opcode=instruction.opcode();
            if(subroutine(opcode)) throw rejected("subroutine-flow");
            for(var region:regions) {
                if(inside(i,region.start(),region.end()) && (instruction instanceof ReturnInstruction || opcode==Opcode.ATHROW
                        || instruction instanceof LookupSwitchInstruction || instruction instanceof TableSwitchInstruction))
                    throw rejected(region.name()+"-control-flow");
            }

            if(instruction instanceof BranchInstruction branch) {
                addBranch(edges,positions,i,branch.target(),size,regions);
                if(opcode!=Opcode.GOTO && opcode!=Opcode.GOTO_W) addFallthrough(edges,i,size);
            } else if(instruction instanceof LookupSwitchInstruction selection) {
                addBranch(edges,positions,i,selection.defaultTarget(),size,regions);
                for(var arm:selection.cases()) addBranch(edges,positions,i,arm.target(),size,regions);
            } else if(instruction instanceof TableSwitchInstruction selection) {
                addBranch(edges,positions,i,selection.defaultTarget(),size,regions);
                for(var arm:selection.cases()) addBranch(edges,positions,i,arm.target(),size,regions);
            } else if(!(instruction instanceof ReturnInstruction) && opcode!=Opcode.ATHROW) {
                addFallthrough(edges,i,size);
            }

            if(instruction instanceof InvokeInstruction call && call.owner().asInternalName().equals(TARGET)) {
                if(GUARDED_CONTROLS.containsKey(call.name().stringValue())) {
                    guardStarts.put(i,validateCall(instructions,positions,i,call,modeSlot,speedSlot));
                    protectedCalls.add(i);
                    if(call.name().equalsString("control_Braking")) brakingCall=i;
                }
                if(call.name().equalsString("updateBackSignal") && call.type().equalsString("()V")) backSignalCall=i;
            }
        }
        if(protectedCalls.size()!=GUARDED_CONTROLS.size() || brakingCall<0 || backSignalCall<0)
            throw rejected("guarded-call-sites");
        int phaseEnd=brakingCall+1;
        for(var handler:catches) {
            int start=position(positions,handler.tryStart(),size,true);
            int end=position(positions,handler.tryEnd(),size,true);
            int target=position(positions,handler.handler(),size,false);
            if(start>=end) throw rejected("exception-range");
            if(start<phaseEnd && end>entryIndex || inside(target,entryIndex,phaseEnd))
                throw rejected("control-phase-exception-flow");
            for(var region:regions) {
                if(start<region.end() && end>region.start() || inside(target,region.start(),region.end()))
                    throw rejected(region.name()+"-exception-flow");
            }
            // Every protected instruction may throw: conservative exceptional edges prevent a handler bypass.
            for(int i=start;i<end;i++) edges.get(i).add(target);
        }

        for(int call:protectedCalls) {
            int start=guardStarts.get(call);
            for(int from=0;from<size;from++) if(from<start || from>call) {
                for(int to:edges.get(from)) if(to>start && to<=call) throw rejected("owned-call-guard-entry");
            }
        }
        var checkpoints=new ArrayList<Integer>(guardStarts.values());
        checkpoints.add(backSignalCall);
        validateControlPhase(edges,entryIndex,phaseEnd,checkpoints);
        protectedCalls.add(steeringStart);
        boolean[] reachable=reachable(edges,List.of(0),-1);
        boolean[] bypass=reachable(edges,List.of(0),entryIndex);
        if(!reachable[offroadCall] || bypass[offroadCall]) throw rejected("offroad-dispatch-bypass");
        for(int call:protectedCalls) {
            if(!reachable[call] || bypass[call]) throw rejected("dispatch-bypass");
        }
        boolean[] afterDispatch=reachable(edges,List.of(entryIndex),-1);
        var reverse=new ArrayList<List<Integer>>(size);
        for(int i=0;i<size;i++) reverse.add(new ArrayList<>());
        for(int i=0;i<size;i++) for(int target:edges.get(i)) reverse.get(target).add(i);
        boolean[] beforeControl=reachable(reverse,protectedCalls,-1);
        for(int i=0;i<size;i++) {
            if(!reachable[i] || !beforeControl[i]) continue;
            Instruction instruction=instructions.get(i);
            // Reassigning slot zero changes the receiver of our injected calls, even before dispatch.
            if(writesSlot(instruction,0)) throw rejected("controller-receiver-slot");
            if(afterDispatch[i] && (writesSlot(instruction,modeSlot) || writesSlot(instruction,speedSlot)))
                throw rejected("dispatch-local-write");
        }
    }

    private static void validateControlPhase(List<List<Integer>> edges,int entry,int end,List<Integer> checkpoints) {
        if(entry<0 || end<=entry || end>=edges.size()) throw rejected("control-phase-boundaries");
        boolean[] afterEntry=reachable(edges,List.of(entry),-1);
        for(int from=0;from<edges.size();from++) {
            boolean inPhase=inside(from,entry,end);
            // No explicit return/throw may abandon a phase after the dispatch has committed.
            if(inPhase && edges.get(from).isEmpty()) throw rejected("control-phase-early-exit");
            for(int to:edges.get(from)) {
                if(inPhase) {
                    if(to<=from) throw rejected("control-phase-cycle");
                    if(to>end) throw rejected("control-phase-exit");
                } else if(to>entry && to<end) {
                    throw rejected("control-phase-interior-entry");
                }
                // Also catch end -> pre-entry -> entry, not just loops inside the phase.
                if(to==entry && afterEntry[from]) throw rejected("control-phase-reentry");
            }
        }
        if(!afterEntry[end]) throw rejected("control-phase-unreachable-end");
        for(int checkpoint:checkpoints) {
            if(!inside(checkpoint,entry,end) || !afterEntry[checkpoint]
                    || reachable(edges,List.of(entry),checkpoint)[end])
                throw rejected("control-phase-checkpoint-bypass");
        }
    }

    private static void validateMembers(ClassModel model) {
        if(!model.thisClass().asInternalName().equals(TARGET)) throw rejected("controller-type");
        var updates=model.methods().stream().filter(m->m.methodName().equalsString("update")
            && m.methodType().equalsString("()V")).toList();
        if(updates.size()!=1 || updates.getFirst().code().isEmpty()
                || (updates.getFirst().flags().flagsMask()&(ClassFile.ACC_STATIC|ClassFile.ACC_ABSTRACT|ClassFile.ACC_NATIVE))!=0)
            throw rejected("instance-update");
        for(var required:FIELDS.entrySet()) {
            var matches=model.fields().stream().filter(f->f.fieldName().equalsString(required.getKey())).toList();
            if(matches.size()!=1 || !matches.getFirst().fieldType().equalsString(required.getValue())
                    || (matches.getFirst().flags().flagsMask()&ClassFile.ACC_STATIC)!=0)
                throw rejected("field:"+required.getKey());
            if(Set.of("isGas","isGasR","isBreak","vehicleSteering").contains(required.getKey())
                    && (matches.getFirst().flags().flagsMask()&ClassFile.ACC_FINAL)!=0)
                throw rejected("readonly-field:"+required.getKey());
        }
    }

    private static void validateCallOrder(List<Instruction> instructions) {
        int next=0;
        for(var instruction:instructions) if(instruction instanceof InvokeInstruction call) {
            String key=call.owner().asInternalName()+"."+call.name().stringValue()+call.type().stringValue();
            if(!CALL_ORDER.contains(key)) continue;
            if(next>=CALL_ORDER.size() || !CALL_ORDER.get(next++).equals(key)) throw rejected("control-call-order");
            boolean nativeCall=call.owner().asInternalName().equals("zombie/core/physics/Bullet");
            if(nativeCall?call.opcode()!=Opcode.INVOKESTATIC:
                    call.opcode()!=Opcode.INVOKEVIRTUAL && call.opcode()!=Opcode.INVOKESPECIAL)
                throw rejected("control-call-kind");
        }
        if(next!=CALL_ORDER.size()) throw rejected("control-call-order");
    }

    private static int validateCall(List<Instruction> instructions,Map<Label,Integer> positions,int index,
            InvokeInstruction call,int modeSlot,int speedSlot) {
        boolean hasSpeed=call.name().equalsString("control_ForwardNew") || call.name().equalsString("control_Reverse");
        if(!call.type().equalsString(hasSpeed?"(F)V":"()V")
                || call.opcode()!=Opcode.INVOKEVIRTUAL && call.opcode()!=Opcode.INVOKESPECIAL)
            throw rejected("owned-call-signature");
        int previous=previousInstruction(instructions,index);
        if(hasSpeed) {
            if(previous<0 || !(instructions.get(previous) instanceof LoadInstruction speed)
                    || speed.typeKind()!=TypeKind.FLOAT || speed.slot()!=speedSlot)
                throw rejected("owned-call-speed");
            previous=previousInstruction(instructions,previous);
        }
        if(previous<0 || !(instructions.get(previous) instanceof LoadInstruction self)
                || self.typeKind()!=TypeKind.REFERENCE || self.slot()!=0)
            throw rejected("owned-call-receiver");
        String state=GUARDED_CONTROLS.get(call.name().stringValue());
        if(state==null) throw rejected("guarded-call-name");
        // Dispatching before a call is only equivalent when that call is still gated by the
        // same resolved mode. Counts and argument types alone cannot establish that contract.
        if(previous<3 || !(instructions.get(previous-1) instanceof BranchInstruction guard)
                || guard.opcode()!=Opcode.IF_ACMPNE || position(positions,guard.target(),instructions.size(),false)!=index+1
                || !(instructions.get(previous-2) instanceof FieldInstruction mode)
                || mode.opcode()!=Opcode.GETSTATIC || !mode.owner().asInternalName().equals(TARGET+"$ControlState")
                || !mode.name().equalsString(state) || !mode.type().equalsString("L"+TARGET+"$ControlState;")
                || !(instructions.get(previous-3) instanceof LoadInstruction resolved)
                || resolved.typeKind()!=TypeKind.REFERENCE || resolved.slot()!=modeSlot)
            throw rejected("owned-call-guard");
        return previous-3;
    }

    private static int previousInstruction(List<Instruction> instructions,int index) {
        do { index--; } while(index>=0 && instructions.get(index).opcode()==Opcode.NOP);
        return index;
    }

    private static void addBranch(List<List<Integer>> edges,Map<Label,Integer> positions,int source,Label label,
            int size,List<Region> regions) {
        int target=position(positions,label,size,false);
        for(var region:regions) {
            if(inside(source,region.start(),region.end())) {
                if(!inside(target,region.start(),region.end()) && target!=region.end()) throw rejected(region.name()+"-exit");
            } else if((target>region.start() || region.name().equals("offroad") && target==region.start())
                    && target<region.end()) {
                // Steering has a dispatcher at its first instruction; offroad is guarded before its true-body.
                throw rejected(region.name()+"-interior-entry");
            }
        }
        edges.get(source).add(target);
    }

    private static void addFallthrough(List<List<Integer>> edges,int source,int size) {
        if(source+1>=size) throw rejected("unterminated-update");
        edges.get(source).add(source+1);
    }

    private static int position(Map<Label,Integer> positions,Label label,int size,boolean allowEnd) {
        Integer position=positions.get(label);
        if(position==null || position<0 || position>size || position==size && !allowEnd)
            throw rejected("unbound-control-label");
        return position;
    }

    private static boolean[] reachable(List<List<Integer>> edges,List<Integer> starts,int blocked) {
        boolean[] seen=new boolean[edges.size()];
        var pending=new ArrayDeque<Integer>();
        for(int start:starts) if(start!=blocked && !seen[start]) { seen[start]=true; pending.add(start); }
        while(!pending.isEmpty()) {
            for(int target:edges.get(pending.removeFirst())) {
                if(target!=blocked && !seen[target]) { seen[target]=true; pending.addLast(target); }
            }
        }
        return seen;
    }

    private static boolean writesSlot(Instruction instruction,int slot) {
        if(instruction instanceof IncrementInstruction increment) return increment.slot()==slot;
        if(!(instruction instanceof StoreInstruction store)) return false;
        int width=store.typeKind()==TypeKind.LONG || store.typeKind()==TypeKind.DOUBLE?2:1;
        return slot>=store.slot() && slot<store.slot()+width;
    }

    private static boolean inside(int value,int start,int end) { return value>=start && value<end; }
    private static boolean subroutine(Opcode opcode) {
        return switch(opcode.name()) { case "JSR", "JSR_W", "RET", "RET_W" -> true; default -> false; };
    }
    private static IllegalArgumentException rejected(String reason) {
        return new IllegalArgumentException("unsupported-patch-contract:"+reason);
    }
}
