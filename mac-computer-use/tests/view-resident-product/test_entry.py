"""Exact measured SwiftUI startup; synthetic independent app names and symbol proof."""
import copy
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'skills/mac-computer-use/scripts/view-capture'))
import edit_backend as e

class Entry(unittest.TestCase):
    def frames(self):
        runtime = '/selected/RuntimeRoot'; framework = runtime + '/System/Library/'
        rows = [(n, '/usr/lib/system/libsystem_kernel.dylib') for n in ('mach_msg2_trap','mach_msg2_internal','mach_msg_overwrite','mach_msg')]
        rows += [(n,framework+'Frameworks/CoreFoundation.framework/CoreFoundation') for n in ('__CFRunLoopServiceMachPort','__CFRunLoopRun','_CFRunLoopRunSpecificWithOptions')]
        rows += [('GSEventRunModal',framework+'PrivateFrameworks/GraphicsServices.framework/GraphicsServices'),('UIApplicationMain',framework+'PrivateFrameworks/UIKitCore.framework/UIKitCore')]
        rows += [(n,framework+'Frameworks/SwiftUI.framework/SwiftUI') for n in e.SWIFTUI_STARTUP]
        rows += [('static Notes.Entry.$main() -> ()','/app/Notes'),('main','/app/Notes'),('start_sim',runtime+'/usr/lib/dyld_sim'),('start','/usr/lib/dyld')]
        frames = [dict(function=n,module=m) for n,m in rows]
        frames[12]['symbol'] = dict(name=frames[12]['function'],mangled='$s5Notes5EntryV5$mainyyFZ',module='/app/Notes',start=100,pc=104,end=120)
        return frames
    def accepts(self, frames):
        return e.safe_entry(frames,'/app/Notes','/selected/RuntimeRoot')
    def test_measured_shape_with_independent_nominal_app(self):
        self.assertTrue(self.accepts(self.frames()))
    def test_insertions_deletions_and_wrong_order(self):
        for i in range(16):
            for kind in ('delete','insert','swap'):
                f=self.frames()
                if kind=='delete':f.pop(i)
                elif kind=='insert':f.insert(i,copy.deepcopy(f[i]))
                else:f[i],f[(i+1)%16]=f[(i+1)%16],f[i]
                with self.subTest(i=i,kind=kind):self.assertFalse(self.accepts(f))
    def test_every_frame_symbol_and_module_is_bound(self):
        for i in range(16):
            for field,value in [('function','callback'),('module','/wrong/RuntimeRoot/System/Library/SwiftUI')]:
                f=self.frames();f[i][field]=value
                with self.subTest(i=i,field=field):self.assertFalse(self.accepts(f))
        self.assertFalse(e.safe_entry(self.frames(),'/app/Other','/selected/RuntimeRoot'))
        self.assertFalse(e.safe_entry(self.frames(),'/app/Notes','/other/RuntimeRoot'))
    def test_generated_symbol_proof_is_required(self):
        for field,value in [('name','static Notes.Fake.$main() -> ()'),('mangled','$s5Notes5EntryV4mainyyFZ'),('mangled','fake5$mainyyFZ'),('module','/other/Notes'),('start',105),('end',104),('pc',None),('pc',True),('end',2**64-1)]:
            f=self.frames();f[12]['symbol'][field]=value
            with self.subTest(field=field,value=value):self.assertFalse(self.accepts(f))
        f=self.frames();del f[12]['symbol'];self.assertFalse(self.accepts(f))
        for name in ('static Notes.Entry.main() -> ()','static Notes.Entry.Nested.$main() -> ()','static Notes.Entry$main() -> ()','static Notes.'+'A'*129+'.$main() -> ()'):
            f=self.frames();f[12]['function']=f[12]['symbol']['name']=name;self.assertFalse(self.accepts(f))

if __name__=='__main__':unittest.main()
