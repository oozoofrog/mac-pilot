"""Headless LLDB API doubles: symbol policy, never target timing evidence."""
import sys
from pathlib import Path
import unittest
from unittest.mock import Mock
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'skills/mac-computer-use/scripts/view-capture'))
import resident_transport as t

class EntryLookup(unittest.TestCase):
    def test_exact_all_types_and_no_linear_scan(self):
        m=Mock(); api=Mock(); symbols=m.FindSymbols.return_value
        symbols.GetSize.return_value=1
        symbol=symbols.GetContextAtIndex.return_value.GetSymbol.return_value
        symbol.GetName.return_value='mac_cu_resident_submit_v2'
        symbol.GetType.return_value=api.eSymbolTypeCode
        self.assertIs(t.resident_entry(m,api),symbol)
        m.FindSymbols.assert_called_once_with('mac_cu_resident_submit_v2',api.eSymbolTypeAny)
        m.GetNumSymbols.assert_not_called()
    def test_duplicate_missing_wrong_type_and_wrong_name(self):
        for count,name,kind in [(0,'mac_cu_resident_submit_v2',1),(2,'mac_cu_resident_submit_v2',1),(1,'other',1),(1,'mac_cu_resident_submit_v2',2)]:
            m=Mock(); api=Mock(eSymbolTypeCode=1); entries=m.FindSymbols.return_value
            entries.GetSize.return_value=count
            symbol=entries.GetContextAtIndex.return_value.GetSymbol.return_value
            symbol.GetName.return_value=name;symbol.GetType.return_value=kind
            with self.assertRaises(RuntimeError):t.resident_entry(m,api)

class EngineReadiness(unittest.TestCase):
    def engine(self,image):
        e=object.__new__(t.Engine);e.control=Mock();e.check_server=Mock();e.active_call=None
        e.lldb=Mock(eSymbolTypeCode=1,eStateStopped=5,LLDB_INVALID_IMAGE_TOKEN=-1)
        e.target=Mock();e.process=Mock();e.frame=Mock()
        e.target.GetTriple.return_value='arm64-apple-ios-simulator'
        m=e.target.GetModuleAtIndex.return_value;e.target.GetNumModules.return_value=1
        m.GetUUIDString.return_value='UUID';m.GetFileSpec.return_value=str(image)
        exports=e.target.FindGlobalFunctions.return_value;exports.GetSize.return_value=1
        context=exports.GetContextAtIndex.return_value;context.GetFunction.return_value.GetName.return_value='mac_cu_resident_submit_v2';context.GetModule.return_value=m
        e.target.FindFunctions.side_effect=lambda name:Mock(GetSize=Mock(return_value=int(name.endswith('_v2'))))
        matches=m.FindSymbols.return_value;matches.GetSize.return_value=1
        symbol=matches.GetContextAtIndex.return_value.GetSymbol.return_value
        symbol.GetName.return_value='mac_cu_resident_submit_v2';symbol.GetType.return_value=1
        symbol.GetStartAddress.return_value.GetLoadAddress.return_value=1000
        section=m.FindSection.return_value.FindSubSection.return_value
        section.IsValid.return_value=True;section.GetLoadAddress.return_value=900;section.GetByteSize.return_value=200
        m.GetNumSections.return_value=0
        return e,m,context,symbol,section
    def test_deadline_or_cancellation_checkpoint_prevents_submission(self):
        import tempfile
        for reason in ('bootstrap deadline exceeded','cancelled'):
            with tempfile.TemporaryDirectory() as directory:
                root=Path(directory).resolve();image=root/'mac-cu-resident.dylib';image.touch()
                e,*_=self.engine(image);e.control.side_effect=[None,RuntimeError(reason)]
                with self.assertRaisesRegex(RuntimeError,reason):e.load_submit(root,str(image),'UUID')
                e.frame.EvaluateExpression.assert_not_called();e.process.LoadImage.assert_not_called()
                self.assertIsNone(e.active_call)
                self.assertFalse((root/'submission-attempt.json').exists())
    def test_uuid_path_text_and_namespace_negatives(self):
        import tempfile
        for fault in ('uuid','path','duplicate-module','text','namespace','duplicate-export'):
            with self.subTest(fault=fault),tempfile.TemporaryDirectory() as directory:
                root=Path(directory).resolve();image=root/'mac-cu-resident.dylib';image.touch()
                e,m,context,symbol,section=self.engine(image)
                if fault=='uuid':m.GetUUIDString.return_value='OTHER'
                if fault=='path':m.GetFileSpec.return_value='/private/wrong.dylib'
                if fault=='duplicate-module':e.target.GetNumModules.return_value=2
                if fault=='text':symbol.GetStartAddress.return_value.GetLoadAddress.return_value=1100
                if fault=='namespace':context.GetFunction.return_value.GetName.return_value='mac_cu_resident_submit_v99'
                if fault=='duplicate-export':e.target.FindGlobalFunctions.return_value.GetSize.return_value=2
                with self.assertRaises(RuntimeError):e.load_submit(root,str(image),'UUID')
                e.frame.EvaluateExpression.assert_not_called();e.process.LoadImage.assert_not_called()

class BootstrapControl(unittest.TestCase):
    def test_real_checkpoint_cancel_and_deadline(self):
        import tempfile
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory,patch.object(t.p,'monotonic',return_value=10):
            folder=Path(directory)
            t.bootstrap_control(folder,11)
            with self.assertRaisesRegex(RuntimeError,'deadline'):t.bootstrap_control(folder,10)
            (folder/'cancel').touch()
            with self.assertRaisesRegex(RuntimeError,'cancelled'):t.bootstrap_control(folder,11)
