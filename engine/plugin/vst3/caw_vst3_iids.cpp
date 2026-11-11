// The VST3 interface ids the wrapper and its test host use. pluginterfaces declares each id in its header; one
// file must define them (Steinberg's public SDK does it in vstinitiids.cpp, which C.A.W does not fetch). The base
// interfaces (FUnknown, IPluginBase, the factories, IBStream) are defined by pluginterfaces/base/coreiids.cpp.
#include <pluginterfaces/vst/ivstaudioprocessor.h>
#include <pluginterfaces/vst/ivstcomponent.h>
#include <pluginterfaces/vst/ivsteditcontroller.h>
#include <pluginterfaces/vst/ivstevents.h>
#include <pluginterfaces/vst/ivstparameterchanges.h>
#include <pluginterfaces/vst/ivstprocesscontext.h>

namespace Steinberg {
namespace Vst {
DEF_CLASS_IID(IComponent)
DEF_CLASS_IID(IAudioProcessor)
DEF_CLASS_IID(IProcessContextRequirements)
DEF_CLASS_IID(IEditController)
DEF_CLASS_IID(IComponentHandler)
DEF_CLASS_IID(IParamValueQueue)
DEF_CLASS_IID(IParameterChanges)
DEF_CLASS_IID(IEventList)
}  // namespace Vst
}  // namespace Steinberg
