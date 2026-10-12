package zombie.core.skinnedmodel.model;

import java.util.ArrayList;
import java.util.List;
import zombie.core.skinnedmodel.advancedanimation.AnimatedModel;
import zombie.core.skinnedmodel.shader.Shader;

/** Synthetic: one model of a vehicle; each draw kept as the shader it was drawn with. */
public final class ModelInstanceRenderData extends AnimatedModel.AnimatedModelInstanceRenderData {
    public static final List<Shader> drawn = new ArrayList<>();
    public void RenderVehicle(ModelSlotRenderData data) { drawn.add(model.effect); }
}
