package pztools.extensions.vehicle;

import java.lang.classfile.*;
import java.lang.classfile.instruction.*;
import java.lang.constant.*;
import java.security.MessageDigest;
import java.util.*;

/** A single resolved-mode dispatch; no game implementation is copied into this module. */
public final class VehicleBytecode {
    public static final String TARGET = "zombie/core/physics/CarController";
    private static final ClassDesc HOOKS = ClassDesc.of("pztools.extensions.api.VehicleHooks");
    private static final ClassDesc CONTROL = ClassDesc.of(TARGET.replace('/', '.'));
    private static final ClassDesc STATE = ClassDesc.of(TARGET.replace('/', '.') + "$ControlState");
    private static final ClassDesc VEHICLE = ClassDesc.of("zombie.vehicles.BaseVehicle");
    private static final MethodTypeDesc DISPATCH = MethodTypeDesc.ofDescriptor("(Ljava/lang/Object;IF)I");
    private static final Set<String> OWNED_CALLS = Set.of("control_NoControl", "control_ForwardNew", "control_Reverse");
    private VehicleBytecode() { }

    public static byte[] fingerprint(byte[] source, ClassLoader loader) {
        var cf = format(loader);
        var model = cf.parse(source);
        if (!model.thisClass().asInternalName().equals(TARGET)) throw new IllegalArgumentException("unexpected-controller");
        return cf.build(ClassDesc.of("pztools.validation.ControllerContract"), b -> {
            // The JVM may reorder methods while reconstructing retransformation input.
            var methods=model.methods().stream().sorted(Comparator.comparing((MethodModel m)->m.methodName().stringValue())
                .thenComparing(m->m.methodType().stringValue())).toList();
            for (var method : methods) {
                if (method.code().isEmpty() || method.methodName().equalsString("<init>") || method.methodName().equalsString("<clinit>")) continue;
                var type = method.methodTypeSymbol();
                if ((method.flags().flagsMask() & ClassFile.ACC_STATIC) == 0) type = type.insertParameterTypes(0, CONTROL);
                b.withMethod(method.methodName().stringValue(), type, ClassFile.ACC_PUBLIC | ClassFile.ACC_STATIC,
                    m -> m.transformCode(method.code().orElseThrow(), CodeTransform.ACCEPT_ALL));
            }
        });
    }
    public static String sha256(byte[] bytes) {
        try { return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes)); }
        catch (java.security.NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
    }
    private static ClassFile format(ClassLoader loader) {
        return ClassFile.of(ClassFile.ConstantPoolSharingOption.NEW_POOL,
            ClassFile.DebugElementsOption.DROP_DEBUG, ClassFile.LineNumbersOption.DROP_LINE_NUMBERS,
            ClassFile.ClassHierarchyResolverOption.of(ClassHierarchyResolver.ofClassLoading(loader)));
    }

    /** Caller must additionally pin the resource hash and canonical live fingerprint. */
    public static byte[] transform(byte[] source, ClassLoader loader) {
        var cf = format(loader);
        var model = cf.parse(source);
        if (!model.thisClass().asInternalName().equals(TARGET)) throw new IllegalArgumentException("unexpected-controller");
        var methods = model.methods().stream().filter(m -> m.methodName().equalsString("update") && m.methodType().equalsString("()V")).toList();
        if (methods.size() != 1) throw new IllegalArgumentException("missing-controller-update");
        var code = methods.getFirst().code().orElseThrow();
        List<Instruction> instructions = code.elementStream().filter(Instruction.class::isInstance).map(Instruction.class::cast).toList();
        for (Instruction i : instructions) if (i instanceof InvokeInstruction call && call.owner().asInternalName().equals(HOOKS.descriptorString().substring(1, HOOKS.descriptorString().length()-1)))
            throw new IllegalArgumentException("controller-already-intercepted");
        Map<String,Integer> counts = new HashMap<>();
        for (Instruction i : instructions) if (i instanceof InvokeInstruction call)
            counts.merge(call.owner().asInternalName()+"."+call.name().stringValue()+call.type().stringValue(), 1, Integer::sum);
        require(counts, TARGET+".control_NoControl()V", 1);
        require(counts, TARGET+".control_ForwardNew(F)V", 1);
        require(counts, TARGET+".control_Reverse(F)V", 1);
        require(counts, TARGET+".control_Braking()V", 1);
        require(counts, TARGET+".updateBackSignal()V", 1);
        require(counts, TARGET+".updateBrakeLights()V", 1);
        require(counts, "zombie/vehicles/BaseVehicle.isDoingOffroad()Z", 1);
        require(counts, "zombie/core/physics/Bullet.controlVehicle(IFFF)V", 2);
        require(counts, TARGET+".updateRammingSound(F)V", 1);
        require(counts, "zombie/scripting/objects/VehicleScript.getSteeringClamp(F)F", 1);
        require(counts, "zombie/vehicles/BaseVehicle.setCurrentSteering(F)V", 1);
        int modeSlot = -1, speedSlot = -1, entryIndex = -1;
        int steeringStart=-1,steeringEnd=-1;
        for (int i=0;i+2<instructions.size();i++) {
            if (instructions.get(i) instanceof FieldInstruction f && f.opcode()==Opcode.GETSTATIC
                    && f.owner().asInternalName().equals(TARGET+"$ControlState") && f.name().equalsString("Reverse")
                    && instructions.get(i+1) instanceof StoreInstruction s && s.typeKind()==TypeKind.REFERENCE
                    && instructions.get(i+2) instanceof LoadInstruction l && l.typeKind()==TypeKind.REFERENCE && l.slot()==s.slot()) {
                if (entryIndex >= 0) throw new IllegalArgumentException("ambiguous-mode-join");
                modeSlot=s.slot(); entryIndex=i+2;
            }
            if (i>0 && instructions.get(i) instanceof InvokeInstruction call && call.owner().asInternalName().equals(TARGET)
                    && call.name().equalsString("control_ForwardNew") && instructions.get(i-1) instanceof LoadInstruction l && l.typeKind()==TypeKind.FLOAT)
                speedSlot=l.slot();
            if(instructions.get(i) instanceof InvokeInstruction call && call.owner().asInternalName().equals(TARGET)
                    && call.name().equalsString("updateRammingSound")) steeringStart=i+1;
            if(i>=3 && instructions.get(i) instanceof InvokeInstruction call
                    && call.owner().asInternalName().equals("zombie/scripting/objects/VehicleScript") && call.name().equalsString("getSteeringClamp")
                    && instructions.get(i-3) instanceof LoadInstruction scriptLoad && scriptLoad.typeKind()==TypeKind.REFERENCE
                    && instructions.get(i-2) instanceof LoadInstruction self && self.slot()==0 && self.typeKind()==TypeKind.REFERENCE
                    && instructions.get(i-1) instanceof FieldInstruction speedField && speedField.opcode()==Opcode.GETFIELD
                    && speedField.owner().asInternalName().equals(TARGET) && speedField.name().equalsString("speed")) steeringEnd=i-3;
        }
        if (modeSlot<0 || speedSlot<0 || entryIndex<0) throw new IllegalArgumentException("unsupported-mode-layout");
        if(steeringStart<entryIndex || steeringEnd<=steeringStart || steeringEnd-steeringStart>100
                || !(instructions.get(steeringStart) instanceof LoadInstruction self) || self.slot()!=0 || self.typeKind()!=TypeKind.REFERENCE
                || !(instructions.get(steeringStart+1) instanceof FieldInstruction controls) || !controls.name().equalsString("clientControls")
                || !(instructions.get(steeringStart+2) instanceof FieldInstruction input) || !input.name().equalsString("steering")
                || !(instructions.get(steeringStart+3) instanceof InvokeInstruction absolute) || !absolute.owner().asInternalName().equals("java/lang/Math")
                || !absolute.name().equalsString("abs") || !absolute.type().equalsString("(F)F"))
            throw new IllegalArgumentException("unsupported-steering-layout");
        final int stateLocal=modeSlot, speedLocal=speedSlot;
        final int dispatchIndex=entryIndex;
        final int steeringEntryIndex=steeringStart,steeringEndIndex=steeringEnd;
        byte[] transformed=cf.transformClass(model, ClassTransform.transformingMethodBodies(
            m -> m.methodName().equalsString("update") && m.methodType().equalsString("()V"), CodeTransform.ofStateful(() -> new CodeTransform() {
                int flags, instructionIndex; Label originalSteeringEnd;
                public void atStart(CodeBuilder b) { flags=b.allocateLocal(TypeKind.INT); b.iconst_0().istore(flags); originalSteeringEnd=b.newLabel(); }
                public void accept(CodeBuilder b, CodeElement e) {
                    // The classfile API interns short loads: object identity is not a code position.
                    if(e instanceof Instruction) {
                        int index=instructionIndex++;
                        if(index==dispatchIndex) dispatch(b,stateLocal,speedLocal,flags);
                        if(index==steeringEntryIndex) b.aload(0).iconst_5().fload(speedLocal).invokestatic(HOOKS,"tryControl",DISPATCH)
                            .iconst_1().iand().ifne(originalSteeringEnd);
                        if(index==steeringEndIndex) b.labelBinding(originalSteeringEnd);
                    }
                    if (e instanceof InvokeInstruction call && call.owner().asInternalName().equals(TARGET) && OWNED_CALLS.contains(call.name().stringValue())) {
                        Label original=b.newLabel(), end=b.newLabel();
                        b.iload(flags).iconst_1().iand().ifeq(original);
                        if (call.name().equalsString("control_NoControl")) b.pop(); else b.pop2();
                        b.goto_(end).labelBinding(original).with(e).labelBinding(end);
                    } else if (e instanceof InvokeInstruction call && call.owner().asInternalName().equals("zombie/vehicles/BaseVehicle") && call.name().equalsString("isDoingOffroad")) {
                        b.with(e); Label end=b.newLabel();
                        b.iload(flags).iconst_4().iand().ifeq(end).pop().iconst_0().labelBinding(end);
                    } else if (e instanceof InvokeInstruction call && call.owner().asInternalName().equals("zombie/core/physics/Bullet")
                            && call.name().equalsString("controlVehicle") && call.type().equalsString("(IFFF)V")) {
                        // Observe the exact native arguments, including the engine-off zero-force call.
                        // Spill/reload preserves both values and evaluation order; no native call is added.
                        int steer=b.allocateLocal(TypeKind.FLOAT), brake=b.allocateLocal(TypeKind.FLOAT);
                        int force=b.allocateLocal(TypeKind.FLOAT), id=b.allocateLocal(TypeKind.INT);
                        b.fstore(steer).fstore(brake).fstore(force).istore(id);
                        b.aload(0).fload(force).fload(brake).fload(steer)
                            .invokestatic(HOOKS,"observeNative",MethodTypeDesc.ofDescriptor("(Ljava/lang/Object;FFF)V"));
                        b.iload(id).fload(force).fload(brake).fload(steer).with(e);
                    } else b.with(e);
                }
            })));
        long dispatches=cf.parse(transformed).methods().stream().filter(m -> m.methodName().equalsString("update") && m.methodType().equalsString("()V"))
            .flatMap(m -> m.code().orElseThrow().elementStream())
            .filter(e -> e instanceof InvokeInstruction call && call.owner().asInternalName().equals("pztools/extensions/api/VehicleHooks")
                && call.name().equalsString("tryControl")).count();
        if(dispatches!=2) throw new IllegalStateException("invalid-dispatch-count");
        return transformed;
    }
    private static void dispatch(CodeBuilder b, int state, int speed, int flags) {
        int mode=b.allocateLocal(TypeKind.INT);
        b.iconst_4().istore(mode);
        String[] names={"Forward","Reverse","Braking"};
        for(int i=0;i<names.length;i++) {
            Label next=b.newLabel();
            b.aload(state).getstatic(STATE,names[i],STATE).if_acmpne(next).loadConstant(i+1).istore(mode).labelBinding(next);
        }
        b.aload(0).iload(mode).fload(speed).invokestatic(HOOKS,"tryControl",DISPATCH).istore(flags);
        Label done=b.newLabel();
        b.iload(flags).iconst_2().iand().ifeq(done);
        b.getstatic(STATE,"Braking",STATE).astore(state);
        b.aload(0).iconst_1().putfield(CONTROL,"isBreak",ConstantDescs.CD_boolean);
        b.aload(0).iconst_0().putfield(CONTROL,"isGas",ConstantDescs.CD_boolean);
        b.aload(0).iconst_0().putfield(CONTROL,"isGasR",ConstantDescs.CD_boolean);
        b.aload(0).getfield(CONTROL,"vehicleObject",VEHICLE).fconst_0().putfield(VEHICLE,"throttle",ConstantDescs.CD_float);
        b.labelBinding(done);
    }
    private static void require(Map<String,Integer> counts, String key, int expected) {
        if(counts.getOrDefault(key,0)!=expected) throw new IllegalArgumentException("unsupported-call-count:"+key);
    }
}
