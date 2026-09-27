package pztools.extensions.vehicle;

import java.lang.classfile.*;
import java.lang.classfile.attribute.SourceFileAttribute;
import java.lang.classfile.instruction.*;
import java.lang.constant.*;
import java.net.*;
import java.nio.file.*;
import java.util.*;
import java.util.function.*;

/** Mutates hand-authored fixtures only; never loads an installed game or attaches to a JVM. */
public final class VehicleCompatibilityTest {
    private static final ClassDesc CONTROL=ClassDesc.of("zombie.core.physics.CarController");
    private static final ClassDesc STATE=ClassDesc.of("zombie.core.physics.CarController$ControlState");
    private static final ClassDesc SYSTEM=ClassDesc.of("java.lang.System");
    private static final MethodTypeDesc CLOCK=MethodTypeDesc.of(ConstantDescs.CD_long);
    private static ClassFile format;
    private static ClassLoader loader;
    private static byte[] baseline;
    private static Map<String,String> contracts;
    private static int cases;
    private static final List<Throwable> failures=new ArrayList<>();

    public static void main(String[] args) throws Exception {
        if(args.length!=1) throw new IllegalArgumentException("fixture classes directory required");
        Path fixture=Path.of(args[0]);
        baseline=Files.readAllBytes(fixture.resolve(VehicleBytecode.TARGET+".class"));
        try(var resolver=new URLClassLoader(new URL[]{fixture.toUri().toURL()},VehicleCompatibilityTest.class.getClassLoader())) {
            loader=resolver;
            format=ClassFile.of(ClassFile.ClassHierarchyResolverOption.of(ClassHierarchyResolver.ofClassLoading(loader)));
            contracts=VehicleBytecode.controlContracts(baseline,loader);
            run("baseline",()->accepted("baseline",baseline));
            run("immutable explicit fixture contracts",VehicleCompatibilityTest::immutableContracts);
            run("unrelated class members",()->accepted("unrelated class members",extraMembers()));
            run("method order and source metadata",()->accepted("method order and source metadata",reorderMethods()));
            run("update observer outside the replaced region",()->accepted("outside observer",edit("update",new CodeTransform() {
                public void atStart(CodeBuilder b) { clock(b); }
                public void accept(CodeBuilder b,CodeElement e) { b.with(e); }
            })));
            run("early return before the protected region",()->accepted("pre-dispatch early return",edit("update",new CodeTransform() {
                public void atStart(CodeBuilder b) { conditionalReturn(b); }
                public void accept(CodeBuilder b,CodeElement e) { b.with(e); }
            })));
            run("helper NOP and line metadata",()->accepted("helper NOP",edit("control_ForwardNew",new CodeTransform() {
                public void atStart(CodeBuilder b) { b.lineNumber(12345).nop(); }
                public void accept(CodeBuilder b,CodeElement e) { b.with(e); }
            })));
            run("NOPs between every update instruction",VehicleCompatibilityTest::nopAnchors);
            run("changed helper constant",()->rejectedHelper("helper constant",changedHelperConstant()));
            run("changed helper branch",()->rejectedHelper("helper branch",changedHelperBranch()));
            run("changed helper branch target",()->rejectedHelper("helper branch target",changedHelperBranchTarget()));
            run("extra helper invocation",()->rejectedHelper("helper invocation",edit("control_NoControl",new CodeTransform() {
                public void atStart(CodeBuilder b) { clock(b); }
                public void accept(CodeBuilder b,CodeElement e) { b.with(e); }
            })));
            run("missing replaced helper",()->rejected("missing helper",format.transformClass(format.parse(baseline),
                ClassTransform.dropping(e->e instanceof MethodModel m && m.methodName().equalsString("control_Reverse"))),"unsupported-"));
            run("changed required field type",()->rejected("field type",changedFieldType(),"unsupported-"));
            run("injected field write targets a final field",()->rejected("final isGas field",finalInjectedField(),"unsupported-"));
            run("missing original forward invocation",()->rejected("missing forward invocation",missingForwardCall(),"unsupported-"));
            run("reversed helper caller guard",()->rejected("helper caller guard",changedForwardGuard(),"unsupported-"));
            run("reversed braking caller guard",()->rejectedBoundary("braking caller guard",changedBrakeGuard()));
            run("loop depends on a skipped helper",()->rejectedBoundary("helper-dependent back edge",helperDependentLoop()));
            run("early return after dispatch before helpers",()->rejectedBoundary("post-dispatch early return",earlyReturnAfterDispatch()));
            run("branch skips every protected helper guard",()->rejectedBoundary("helper bundle bypass",skipHelperPhase()));
            run("post-phase branch reenters through a pre-entry trampoline",()->rejectedBoundary("indirect phase reentry",reenterHelperPhase()));
            run("extra invocation inside steering",()->rejected("steering invocation",afterSteeringWrite(VehicleCompatibilityTest::clock),"unsupported-"));
            run("extra field write inside steering",()->rejected("steering side effect",afterSteeringWrite(
                b->b.aload(0).iconst_2().putfield(CONTROL,"vehicleId",ConstantDescs.CD_int)),"unsupported-"));
            run("extra invocation inside skipped offroad branch",()->rejected("offroad side effect",extraOffroadCall(),"unsupported-"));
            run("external branch enters steering interior",()->rejected("incoming steering branch",incomingSteeringBranch(),"unsupported-"));
            run("steering branch bypasses post-processing",()->rejected("outgoing steering branch",outgoingSteeringBranch(),"unsupported-"));
            run("exception handler overlaps steering",()->rejected("steering exception handler",steeringExceptionHandler(),"unsupported-"));
            run("branch bypasses dispatch",()->rejected("dispatch bypass",bypassDispatch(),"unsupported-"));
            run("mode local changes after dispatch",()->rejected("changed mode local",changedDispatchLocal("mode"),"unsupported-"));
            run("speed local changes after dispatch",()->rejected("changed speed local",changedDispatchLocal("speed"),"unsupported-"));
            run("controller local changes after dispatch",()->rejected("changed controller local",changedDispatchLocal("this"),"unsupported-"));
            run("duplicate transformation",()->rejected("duplicate hook",transform(baseline),"controller-already-intercepted"));
        }
        if(!failures.isEmpty()) {
            var failed=new AssertionError("Vehicle compatibility: "+failures.size()+" of "+cases+" cases failed");
            failures.forEach(failed::addSuppressed);
            throw failed;
        }
        System.out.println("PASS vehicle compatibility: "+cases+" cases (synthetic class mutations only)");
    }

    private static void immutableContracts() {
        check(contracts.keySet().equals(Set.of("control_NoControl","control_ForwardNew","control_Reverse","@steering","@offroad")),"exact replaced-code scope");
        try { contracts.put("control_NoControl","not-a-contract"); }
        catch(UnsupportedOperationException expected) { return; }
        throw new AssertionError("fixture contracts must be immutable");
    }

    private static byte[] extraMembers() {
        return format.transformClass(format.parse(baseline),ClassTransform.endHandler(b->{
            b.withField("compatibilityMarker",ConstantDescs.CD_long,ClassFile.ACC_PRIVATE|ClassFile.ACC_STATIC);
            b.withMethodBody("compatibilityMarker",MethodTypeDesc.of(ConstantDescs.CD_void),
                ClassFile.ACC_PRIVATE|ClassFile.ACC_STATIC,CodeBuilder::return_);
        }));
    }

    private static void nopAnchors() {
        byte[] source=edit("update",(b,e)->{
            if(e instanceof Instruction) b.nop();
            b.with(e);
        });
        accepted("NOP anchors",source);
        check(nops(source)>0,"fixture mutation contains NOPs");
        check(nops(transform(source))==nops(source),"transform must preserve the original harmless NOPs");
    }
    private static long nops(byte[] source) {
        return format.parse(source).methods().stream().filter(m->m.methodName().equalsString("update"))
            .flatMap(m->m.code().orElseThrow().elementStream()).filter(e->e instanceof Instruction i && i.opcode()==Opcode.NOP).count();
    }

    private static byte[] reorderMethods() {
        return format.transformClass(format.parse(baseline),new ClassTransform() {
            final List<MethodModel> methods=new ArrayList<>();
            public void accept(ClassBuilder b,ClassElement e) {
                if(e instanceof MethodModel m) methods.add(m);
                else if(!(e instanceof SourceFileAttribute)) b.with(e);
            }
            public void atEnd(ClassBuilder b) {
                for(var m:methods.reversed()) b.with(m);
                b.with(SourceFileAttribute.of("UnrelatedMetadata.java"));
            }
        });
    }

    private static byte[] changedHelperConstant() {
        int[] changed={0};
        byte[] result=edit("control_ForwardNew",(b,e)->{
            if(changed[0]==0 && e instanceof ConstantInstruction c && c.constantValue() instanceof Float value) {
                b.loadConstant(value+1f); changed[0]++;
            } else b.with(e);
        });
        check(changed[0]==1,"fixture has a forward force constant");
        return result;
    }

    private static byte[] changedHelperBranch() {
        int[] changed={0};
        byte[] result=edit("control_ForwardNew",(b,e)->{
            if(changed[0]==0 && e instanceof BranchInstruction branch
                    && (branch.opcode()==Opcode.IFEQ || branch.opcode()==Opcode.IFNE)) {
                b.branch(branch.opcode()==Opcode.IFEQ?Opcode.IFNE:Opcode.IFEQ,branch.target()); changed[0]++;
            } else b.with(e);
        });
        check(changed[0]==1,"fixture has a parking-brake branch");
        return result;
    }

    private static byte[] changedFieldType() {
        return format.transformClass(format.parse(baseline),(b,e)->{
            if(e instanceof FieldModel field && field.fieldName().equalsString("vehicleSteering"))
                b.withField("vehicleSteering",ConstantDescs.CD_double,field.flags().flagsMask());
            else b.with(e);
        });
    }

    private static byte[] finalInjectedField() {
        return format.transformClass(format.parse(baseline),(b,e)->{
            if(e instanceof FieldModel field && field.fieldName().equalsString("isGas"))
                b.withField("isGas",field.fieldTypeSymbol(),field.flags().flagsMask()|ClassFile.ACC_FINAL);
            else b.with(e);
        });
    }

    private static byte[] changedForwardGuard() {
        return editUpdate((code,region)->{
            int guard=-1;
            for(int i=3;i<region.instructions().size();i++) if(call(region.instructions().get(i),"control_ForwardNew")) guard=i-3;
            check(guard>=0 && region.instructions().get(guard) instanceof BranchInstruction branch
                && branch.opcode()==Opcode.IF_ACMPNE,"fixture has a forward enum guard");
            final int selected=guard;
            return new CodeTransform() {
                int index;
                public void accept(CodeBuilder b,CodeElement e) {
                    if(e instanceof Instruction && index++==selected) {
                        b.if_acmpeq(((BranchInstruction)e).target());
                    } else b.with(e);
                }
            };
        });
    }

    private static byte[] changedBrakeGuard() {
        return editUpdate((code,region)->{
            int guard=-1;
            for(int i=2;i<region.instructions().size();i++) if(call(region.instructions().get(i),"control_Braking")) guard=i-2;
            check(guard>=0 && region.instructions().get(guard) instanceof BranchInstruction branch
                && branch.opcode()==Opcode.IF_ACMPNE,"fixture has a braking enum guard");
            final int selected=guard;
            return new CodeTransform() {
                int index;
                public void accept(CodeBuilder b,CodeElement e) {
                    if(e instanceof Instruction && index++==selected) b.if_acmpeq(((BranchInstruction)e).target());
                    else b.with(e);
                }
            };
        });
    }

    private static byte[] helperDependentLoop() {
        return editUpdate((code,region)->{
            int invocation=-1;
            for(int i=5;i<region.instructions().size();i++) if(call(region.instructions().get(i),"control_ForwardNew")) invocation=i;
            check(invocation>=5,"fixture has a forward call with an enum guard");
            final int call=invocation,start=call-5;
            check(region.instructions().get(start) instanceof LoadInstruction load && load.typeKind()==TypeKind.REFERENCE,
                "fixture forward guard starts by reading its mode");
            final int mode=((LoadInstruction)region.instructions().get(start)).slot();
            return new CodeTransform() {
                int index; Label again;
                public void atStart(CodeBuilder b) { again=b.newLabel(); }
                public void accept(CodeBuilder b,CodeElement e) {
                    if(e instanceof Instruction) {
                        if(index==start) b.labelBinding(again);
                        if(index==call+1) {
                            // Original execution increments forwardCalls twice and finishes. An APPLIED
                            // hook skips that increment, so accepting this loop could hang the game thread.
                            // This regression only verifies/rejects bytes; it never executes the loop.
                            Label done=b.newLabel();
                            b.aload(mode).getstatic(STATE,"Forward",STATE).if_acmpne(done)
                                .aload(0).getfield(CONTROL,"forwardCalls",ConstantDescs.CD_int).iconst_2().if_icmplt(again)
                                .labelBinding(done);
                        }
                        index++;
                    }
                    b.with(e);
                }
            };
        });
    }

    private static byte[] earlyReturnAfterDispatch() {
        int[] changed={0};
        byte[] result=edit("update",(b,e)->{
            b.with(e);
            if(e instanceof FieldInstruction field && field.opcode()==Opcode.PUTFIELD
                    && field.owner().asInternalName().equals(VehicleBytecode.TARGET) && field.name().equalsString("speedRequests")) {
                conditionalReturn(b); changed[0]++;
            }
        });
        check(changed[0]==1,"fixture has one post-dispatch speed-request write");
        return result;
    }

    private static byte[] skipHelperPhase() {
        return editUpdate((code,region)->{
            int braking=-1;
            for(int i=0;i<region.instructions().size();i++) if(call(region.instructions().get(i),"control_Braking")) braking=i;
            check(braking>=0,"fixture has a braking phase end");
            final int phaseEnd=braking+1;
            return new CodeTransform() {
                int index,changed; Label exit;
                public void atStart(CodeBuilder b) { exit=b.newLabel(); }
                public void accept(CodeBuilder b,CodeElement e) {
                    if(e instanceof Instruction && index++==phaseEnd) b.labelBinding(exit);
                    b.with(e);
                    if(e instanceof FieldInstruction field && field.opcode()==Opcode.PUTFIELD
                            && field.owner().asInternalName().equals(VehicleBytecode.TARGET) && field.name().equalsString("speedRequests")) {
                        b.aload(0).getfield(CONTROL,"vehicleId",ConstantDescs.CD_int).loadConstant(99).if_icmpeq(exit);
                        changed++;
                    }
                }
                public void atEnd(CodeBuilder b) { check(changed==1,"fixture has one helper-phase bypass site"); }
            };
        });
    }

    private static byte[] reenterHelperPhase() {
        return editUpdate((code,region)->{
            var dispatch=dispatch(region);
            int modeInitialization=-1;
            for(int i=1;i<dispatch.entry();i++) if(region.instructions().get(i) instanceof StoreInstruction store
                    && store.typeKind()==TypeKind.REFERENCE && store.slot()==dispatch.mode()) { modeInitialization=i-1; break; }
            check(modeInitialization>=0,"fixture initializes its mode before dispatch");
            final int preentry=modeInitialization;
            return new CodeTransform() {
                int index,changed; Label trampoline,entry;
                public void atStart(CodeBuilder b) { trampoline=b.newLabel(); entry=b.newLabel(); }
                public void accept(CodeBuilder b,CodeElement e) {
                    if(e instanceof Instruction) {
                        if(index==preentry) {
                            // First entry skips this trampoline and initializes its mode normally.
                            // A later back edge can reuse the initialized locals without a store,
                            // so rejecting only post-dispatch local writes cannot detect the cycle.
                            Label initialize=b.newLabel();
                            b.goto_(initialize).labelBinding(trampoline).goto_(entry).labelBinding(initialize);
                        }
                        if(index==dispatch.entry()) b.labelBinding(entry);
                        index++;
                    }
                    b.with(e);
                    if(call(e,"updateBrakeLights")) {
                        Label done=b.newLabel();
                        b.aload(dispatch.mode()).getstatic(STATE,"Forward",STATE).if_acmpne(done)
                            .aload(0).getfield(CONTROL,"forwardCalls",ConstantDescs.CD_int).iconst_2().if_icmplt(trampoline)
                            .labelBinding(done);
                        changed++;
                    }
                }
                public void atEnd(CodeBuilder b) { check(changed==1,"fixture has one post-phase reentry site"); }
            };
        });
    }

    private static void conditionalReturn(CodeBuilder b) {
        Label proceed=b.newLabel();
        b.aload(0).getfield(CONTROL,"vehicleId",ConstantDescs.CD_int).loadConstant(99).if_icmpne(proceed)
            .return_().labelBinding(proceed);
    }

    private static byte[] changedHelperBranchTarget() {
        boolean[] changed={false};
        byte[] result=edit("control_ForwardNew",new CodeTransform() {
            Label entry;
            public void atStart(CodeBuilder b) { entry=b.newLabel(); b.labelBinding(entry); }
            public void accept(CodeBuilder b,CodeElement e) {
                if(!changed[0] && e instanceof BranchInstruction branch) {
                    b.branch(branch.opcode(),entry); changed[0]=true;
                } else b.with(e);
            }
        });
        check(changed[0],"fixture has a helper branch to retarget");
        return result;
    }

    private static byte[] missingForwardCall() {
        int[] changed={0};
        byte[] result=edit("update",(b,e)->{
            if(call(e,"control_ForwardNew")) { b.pop2(); changed[0]++; }
            else b.with(e);
        });
        check(changed[0]==1,"fixture has one forward invocation");
        return result;
    }

    private static byte[] afterSteeringWrite(Consumer<CodeBuilder> insert) {
        boolean[] region={false},changed={false};
        byte[] result=edit("update",(b,e)->{
            b.with(e);
            if(call(e,"updateRammingSound")) region[0]=true;
            if(region[0] && !changed[0] && e instanceof FieldInstruction f && f.opcode()==Opcode.PUTFIELD
                    && f.owner().asInternalName().equals(VehicleBytecode.TARGET) && f.name().equalsString("vehicleSteering")) {
                insert.accept(b); changed[0]=true;
            }
        });
        check(changed[0],"fixture has a steering write");
        return result;
    }

    private static byte[] incomingSteeringBranch() {
        return editUpdate((code,region)->{
            Label interior=null;
            for(int i=region.start();i<region.end();i++) {
                if(region.instructions().get(i) instanceof BranchInstruction branch) {
                    Integer destination=region.positions().get(branch.target());
                    if(destination!=null && destination>region.start() && destination<region.end()) { interior=branch.target(); break; }
                }
            }
            check(interior!=null,"fixture has an interior steering branch target");
            final Label target=interior;
            int origin=-1;
            for(int i=0;i<region.start();i++) if(call(region.instructions().get(i),"updateBrakeLights")) origin=i;
            check(origin>=0,"fixture has a pre-steering empty-stack boundary after locals are initialized");
            return afterInstruction(origin,b->b.iconst_0().ifne(target));
        });
    }

    private static byte[] extraOffroadCall() {
        boolean[] found={false},changed={false};
        byte[] result=edit("update",(b,e)->{
            b.with(e);
            if(e instanceof InvokeInstruction call && call.owner().asInternalName().equals("zombie/vehicles/BaseVehicle")
                    && call.name().equalsString("isDoingOffroad")) found[0]=true;
            else if(found[0] && !changed[0] && e instanceof BranchInstruction) { clock(b); changed[0]=true; }
        });
        check(changed[0],"fixture has an offroad conditional body");
        return result;
    }

    private static byte[] outgoingSteeringBranch() {
        return editUpdate((code,region)->new CodeTransform() {
            int index; boolean changed; Label exit;
            public void atStart(CodeBuilder b) { exit=b.newLabel(); }
            public void accept(CodeBuilder b,CodeElement e) {
                if(e instanceof Instruction instruction) {
                    int position=index++;
                    if(!changed && position>=region.start() && position<region.end()
                            && instruction instanceof BranchInstruction branch && branch.opcode()==Opcode.GOTO) {
                        b.goto_(exit); changed=true; return;
                    }
                    if(instruction.opcode()==Opcode.RETURN) b.labelBinding(exit);
                }
                b.with(e);
            }
            public void atEnd(CodeBuilder b) { check(changed,"fixture has an outgoing steering join"); }
        });
    }

    private static byte[] steeringExceptionHandler() {
        return editUpdate((code,region)->new CodeTransform() {
            int index; Label start,end,handler;
            public void atStart(CodeBuilder b) { start=b.newLabel(); end=b.newLabel(); handler=b.newLabel(); }
            public void accept(CodeBuilder b,CodeElement e) {
                if(e instanceof Instruction) {
                    if(index==region.start()) b.labelBinding(start);
                    if(index==region.end()) b.labelBinding(end);
                    index++;
                }
                b.with(e);
            }
            public void atEnd(CodeBuilder b) {
                b.labelBinding(handler).athrow().exceptionCatch(start,end,handler,ConstantDescs.CD_Throwable);
            }
        });
    }

    private record Region(List<Instruction> instructions,Map<Label,Integer> positions,int start,int end) { }
    private record Dispatch(int entry,int mode,int speed) { }
    private static Dispatch dispatch(Region region) {
        var instructions=region.instructions();
        int entry=-1,mode=-1,speed=-1;
        for(int i=0;i<instructions.size();i++) {
            if(i+2<instructions.size() && instructions.get(i) instanceof FieldInstruction f
                    && f.opcode()==Opcode.GETSTATIC && f.owner().asInternalName().equals(VehicleBytecode.TARGET+"$ControlState")
                    && f.name().equalsString("Reverse") && instructions.get(i+1) instanceof StoreInstruction store
                    && store.typeKind()==TypeKind.REFERENCE && instructions.get(i+2) instanceof LoadInstruction load
                    && load.typeKind()==TypeKind.REFERENCE && load.slot()==store.slot()) { entry=i+2; mode=store.slot(); }
            if(i>0 && call(instructions.get(i),"control_ForwardNew") && instructions.get(i-1) instanceof LoadInstruction load
                    && load.typeKind()==TypeKind.FLOAT) speed=load.slot();
        }
        check(entry>=0 && mode>=0 && speed>=0,"fixture dispatch is identifiable");
        return new Dispatch(entry,mode,speed);
    }

    private static byte[] changedDispatchLocal(String which) {
        return editUpdate((code,region)->{
            var dispatch=dispatch(region);
            return afterInstruction(dispatch.entry(),b->{
                switch(which) {
                    case "mode" -> b.getstatic(STATE,"Reverse",STATE).astore(dispatch.mode());
                    case "speed" -> b.fconst_0().fstore(dispatch.speed());
                    case "this" -> b.aconst_null().astore(0);
                    default -> throw new AssertionError(which);
                }
            });
        });
    }

    private static byte[] bypassDispatch() {
        return editUpdate((code,region)->{
            var dispatch=dispatch(region);
            int initialStore=-1,firstOwned=-1;
            for(int i=0;i<region.instructions().size();i++) {
                var instruction=region.instructions().get(i);
                if(initialStore<0 && instruction instanceof StoreInstruction store && store.slot()==dispatch.mode()) initialStore=i;
                if(firstOwned<0 && call(instruction,"control_NoControl")) firstOwned=i;
            }
            check(initialStore>=0 && initialStore<dispatch.entry(),"mode initialized before dispatch");
            final int limit=firstOwned;
            Label target=region.positions().entrySet().stream()
                .filter(e->e.getValue()>dispatch.entry() && e.getValue()<limit)
                .min(Map.Entry.comparingByValue()).orElseThrow(()->new AssertionError("post-dispatch branch target")).getKey();
            return afterInstruction(initialStore,b->b.iconst_0().ifne(target));
        });
    }

    private static CodeTransform afterInstruction(int target,Consumer<CodeBuilder> insert) {
        return new CodeTransform() {
            int index;
            public void accept(CodeBuilder b,CodeElement e) {
                b.with(e);
                if(e instanceof Instruction && index++==target) insert.accept(b);
            }
        };
    }

    private static Region region(CodeModel code) {
        var instructions=new ArrayList<Instruction>();
        var positions=new HashMap<Label,Integer>();
        int start=-1,end=-1;
        for(var element:code) {
            if(element instanceof LabelTarget label) positions.put(label.label(),instructions.size());
            if(element instanceof Instruction instruction) {
                if(call(element,"updateRammingSound")) start=instructions.size()+1;
                if(element instanceof InvokeInstruction call && call.owner().asInternalName().equals("zombie/scripting/objects/VehicleScript")
                        && call.name().equalsString("getSteeringClamp")) end=instructions.size()-3;
                instructions.add(instruction);
            }
        }
        check(start>=0 && end>start,"fixture steering region is identifiable");
        return new Region(List.copyOf(instructions),Map.copyOf(positions),start,end);
    }

    private static byte[] editUpdate(BiFunction<CodeModel,Region,CodeTransform> create) {
        var model=format.parse(baseline);
        var code=model.methods().stream().filter(m->m.methodName().equalsString("update") && m.methodType().equalsString("()V"))
            .findFirst().orElseThrow().code().orElseThrow();
        return format.transformClass(model,ClassTransform.transformingMethodBodies(m->m.methodName().equalsString("update"),create.apply(code,region(code))));
    }
    private static byte[] edit(String method,CodeTransform transform) {
        return format.transformClass(format.parse(baseline),ClassTransform.transformingMethodBodies(m->m.methodName().equalsString(method),transform));
    }
    private static boolean call(CodeElement element,String name) {
        return element instanceof InvokeInstruction call && call.owner().asInternalName().equals(VehicleBytecode.TARGET) && call.name().equalsString(name);
    }
    private static void clock(CodeBuilder b) { b.invokestatic(SYSTEM,"nanoTime",CLOCK).pop2(); }
    private static byte[] transform(byte[] source) { return VehicleBytecode.transform(source,loader,contracts); }
    private static void valid(String name,byte[] source) {
        var errors=format.verify(source);
        check(errors.isEmpty(),name+" is not a valid input class: "+errors);
    }
    private static void accepted(String name,byte[] source) {
        valid(name,source);
        check(contracts.equals(VehicleBytecode.controlContracts(source,loader)),name+" must preserve the helper contract");
        byte[] transformed=transform(source);
        valid(name+" transformed",transformed);
        long hooks=format.parse(transformed).methods().stream().filter(m->m.methodName().equalsString("update"))
            .flatMap(m->m.code().orElseThrow().elementStream()).filter(e->e instanceof InvokeInstruction i
                && i.owner().asInternalName().equals("pztools/extensions/api/VehicleHooks") && i.name().equalsString("tryControl")).count();
        check(hooks==2,name+" must have exactly two dispatches");
    }
    private static void rejectedHelper(String name,byte[] source) {
        check(!contracts.equals(VehicleBytecode.controlContracts(source,loader)),name+" must change the helper contract");
        rejected(name,source,"unsupported-control-contract:");
    }
    private static void rejectedBoundary(String name,byte[] source) {
        check(contracts.equals(VehicleBytecode.controlContracts(source,loader)),name+" must leave the replaced code unchanged");
        rejected(name,source,"unsupported-");
    }
    private static void rejected(String name,byte[] source,String reason) {
        valid(name,source);
        try { transform(source); }
        catch(IllegalArgumentException expected) {
            check(expected.getMessage()!=null && expected.getMessage().startsWith(reason),name+" failed for the wrong reason: "+expected);
            return;
        }
        throw new AssertionError(name+" was unexpectedly accepted");
    }
    private static void run(String name,Runnable body) {
        cases++;
        try { body.run(); }
        catch(Throwable failure) { failures.add(new AssertionError(name,failure)); }
    }
    private static void check(boolean condition,String message) { if(!condition) throw new AssertionError(message); }
}
