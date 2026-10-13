-- The markup of typed texts (DESIGN-terminal 14 F2): the UI kit's (PZUIKit.Markup, the language of the extension API's
-- text.show with `markup = true`), by this name here.
require "OperationAcorn/Core"
require "PZUIKit/Markup"
local OA = OperationAcorn
OA.Markup = PZUIKit.Markup

return OA.Markup
