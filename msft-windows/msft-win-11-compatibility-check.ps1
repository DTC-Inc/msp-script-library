#Requires -Version 5.1
<#
.SYNOPSIS
    Checks Windows 11 compatibility using a definitive hybrid approach.
.DESCRIPTION
    This script provides the highest accuracy by using a multi-layered check for CPU compatibility:
    1. It first checks the CPU against a comprehensive, built-in list of officially supported Intel models.
    2. If not on the list, it performs a fallback check for future CPUs by verifying BOTH:
        a) The presence of required hardware security features (VBS/MBEC).
        b) The CPU follows modern naming scheme rules (e.g., >=8th Gen, including 4 and 5-digit models).
.NOTES
    Author: Generated script, updated by AI Assistant
    Version: 3.5 (Modified to detect Windows 11)
    - Added Windows 11 detection - exits with code 1 if already running Windows 11
#>
[CmdletBinding()]
param()

function Test-ImagingMachine {
    # Check if this is a PAN/CEPH/3D imaging capture machine that should be excluded from Windows 11 upgrade
    $computerName = $env:COMPUTERNAME
    
    # Comprehensive regex pattern for dental/medical imaging machine computer names
    # This covers various naming conventions, separators, and vendor-specific patterns
    $imagingPattern = @"
(?ix)  # Case insensitive and ignore whitespace
^.*?   # Optional prefix characters
(?:
    # PAN variations (Panoramic)
    (?:PAN(?:O|ORAMIC)?(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    
    # CEPH variations (Cephalometric)  
    (?:CEPH(?:A|ALOMETRIC)?(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    
    # 3D/CBCT variations
    (?:3D(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    (?:CBCT(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    
    # CAD/CADCAM variations
    (?:CAD(?:CAM)?(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    
    # Radiology/X-ray variations
    (?:(?:X[-_\s]?RAY|XRAY|RADIOLOG(?:Y|IC)|RADIO)(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    (?:(?:DIGITAL|DR|CR|COMPUTED)(?:[-_\s]?(?:RADIOGRAPH(?:Y|IC)|X[-_\s]?RAY|XRAY))?(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    
    # Cone Beam variations
    (?:CONE(?:[-_\s]?BEAM)?(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    
    # Vendor-specific patterns (major dental imaging manufacturers)
    (?:KODAK(?:[-_\s]?(?:PAN|CEPH|3D|CBCT|CAD|CADCAM|XRAY|X[-_\s]?RAY|DR|CR|CS|CARESTREAM))?(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    (?:SIRONA(?:[-_\s]?(?:PAN|CEPH|3D|CBCT|CAD|CADCAM|XRAY|X[-_\s]?RAY|DR|CR|ORTHOPHOS|GALILEOS))?(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    (?:PLANMECA(?:[-_\s]?(?:PAN|CEPH|3D|CBCT|CAD|CADCAM|XRAY|X[-_\s]?RAY|DR|CR|PROMAX|ROMEXIS|VISO))?(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    (?:CARESTREAM(?:[-_\s]?(?:PAN|CEPH|3D|CBCT|CAD|CADCAM|XRAY|X[-_\s]?RAY|DR|CR|CS|KODAK))?(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    (?:DENTSPLY(?:[-_\s]?(?:PAN|CEPH|3D|CBCT|CAD|CADCAM|XRAY|X[-_\s]?RAY|DR|CR|GENDEX|INSTRUMENTARIUM))?(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    (?:GENDEX(?:[-_\s]?(?:PAN|CEPH|3D|CBCT|CAD|CADCAM|XRAY|X[-_\s]?RAY|DR|CR|GXPAN|GXCB))?(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    (?:OWANDY(?:[-_\s]?(?:PAN|CEPH|3D|CBCT|CAD|CADCAM|XRAY|X[-_\s]?RAY|DR|CR|I-MAX))?(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    (?:TROPHY(?:[-_\s]?(?:PAN|CEPH|3D|CBCT|CAD|CADCAM|XRAY|X[-_\s]?RAY|DR|CR|TREX))?(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    (?:KAVO(?:[-_\s]?(?:PAN|CEPH|3D|CBCT|CAD|CADCAM|XRAY|X[-_\s]?RAY|DR|CR|OP))?(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    (?:SOREDEX(?:[-_\s]?(?:PAN|CEPH|3D|CBCT|CAD|CADCAM|XRAY|X[-_\s]?RAY|DR|CR|CRANEX))?(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    (?:YOSHIDA(?:[-_\s]?(?:PAN|CEPH|3D|CBCT|CAD|CADCAM|XRAY|X[-_\s]?RAY|DR|CR))?(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    (?:ACTEON(?:[-_\s]?(?:PAN|CEPH|3D|CBCT|CAD|CADCAM|XRAY|X[-_\s]?RAY|DR|CR|X-MIND))?(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    (?:PHILIPS(?:[-_\s]?(?:PAN|CEPH|3D|CBCT|CAD|CADCAM|XRAY|X[-_\s]?RAY|DR|CR))?(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    (?:MIDMARK(?:[-_\s]?(?:PAN|CEPH|3D|CBCT|CAD|CADCAM|XRAY|X[-_\s]?RAY|DR|CR|PROGENY))?(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    
    # Model-specific patterns
    (?:ORTHOPHOS(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    (?:CRANEX(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    (?:PROMAX(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    (?:VERAVIEW(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    (?:ROMEXIS(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    (?:I[-_\s]?CAT(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    (?:GALILEOS(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    
    # Generic imaging terms with numbers/suffixes
    (?:(?:DENTAL|MEDICAL|XRAY|X[-_\s]?RAY)[-_\s]?(?:PAN|CEPH|3D|CBCT|CAD|CADCAM|IMG|IMAGING)(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    
    # Pattern for combined terms (e.g., PAN3D, CEPH3D, CADCAM3D)
    (?:(?:PAN|CEPH|CAD)(?:[-_\s]?(?:3D|CAM))?(?:[-_\s]?\w*)?(?:[-_\s]?\d+)?)|
    
    # Capture workstation patterns (e.g., PANWS01, CEPHWORKSTATION, CADWS01, XRAYWS01)
    (?:(?:PAN|CEPH|3D|CBCT|CAD|CADCAM|XRAY|X[-_\s]?RAY|DR|CR|RADIO)(?:[-_\s]?(?:WS|WORKSTATION|STATION|PC|COMP))(?:[-_\s]?\d+)?)|
    
    # Room-based naming (e.g., ROOM1PAN, OPPAN1, OP1CEPH, CADROOM1, XRAYROOM1)
    (?:(?:ROOM|OP|OPERATORY)[-_\s]?\d*[-_\s]?(?:PAN|CEPH|3D|CBCT|CAD|CADCAM|XRAY|X[-_\s]?RAY|DR|CR|RADIO)(?:[-_\s]?\d+)?)|
    (?:(?:PAN|CEPH|3D|CBCT|CAD|CADCAM|XRAY|X[-_\s]?RAY|DR|CR|RADIO)[-_\s]?(?:ROOM|OP|OPERATORY)[-_\s]?\d+)
)
.*?$  # Optional suffix characters
"@
    
    if ($computerName -match $imagingPattern) {
        return $true
    }
    
    return $false
}

function Check-Windows11Compatibility {
    #region Master List of Supported Intel CPUs
    $SupportedIntelHashtable = @{
        'Atom x6200FE'=$true; 'Atom x6211E'=$true; 'Atom x6212RE'=$true; 'Atom x6413E'=$true; 'Atom x6414RE'=$true; 'Atom x6425E'=$true; 'Atom x6425RE'=$true; 'Atom x6427FE'=$true;
        'Celeron 6305'=$true; 'Celeron 7300'=$true; 'Celeron 7305'=$true; 'Celeron 3867U'=$true; 'Celeron 4205U'=$true; 'Celeron 4305U'=$true; 'Celeron 4305UE'=$true; 'Celeron 5205U'=$true; 'Celeron 5305U'=$true; 'Celeron 6305E'=$true; 'Celeron 6600HE'=$true; 'Celeron 7305E'=$true; 'Celeron 7305L'=$true; 'Celeron G4900'=$true; 'Celeron G4900T'=$true; 'Celeron G4920'=$true; 'Celeron G4930'=$true; 'Celeron G4930E'=$true; 'Celeron G4930T'=$true; 'Celeron G4932E'=$true; 'Celeron G4950'=$true; 'Celeron G5900'=$true; 'Celeron G5900E'=$true; 'Celeron G5900T'=$true; 'Celeron G5900TE'=$true; 'Celeron G5905'=$true; 'Celeron G5905T'=$true; 'Celeron G5920'=$true; 'Celeron G5925'=$true; 'Celeron G6900'=$true; 'Celeron G6900E'=$true; 'Celeron G6900T'=$true; 'Celeron G6900TE'=$true; 'Celeron J4005'=$true; 'Celeron J4025'=$true; 'Celeron J4105'=$true; 'Celeron J4115'=$true; 'Celeron J4125'=$true; 'Celeron J6412'=$true; 'Celeron J6413'=$true; 'Celeron N4000'=$true; 'Celeron N4020'=$true; 'Celeron N4100'=$true; 'Celeron N4120' = $true; 'Celeron N4500'=$true; 'Celeron N4505'=$true; 'Celeron N5100'=$true; 'Celeron N5105'=$true; 'Celeron N6210'=$true; 'Celeron N6211'=$true;
        'Core 3-100U'=$true; 'Core 5-120U'=$true; 'Core 7-150U'=$true;
        'Core i3-1000G1'=$true; 'Core i3-1000G4'=$true; 'Core i3-1005G1'=$true; 'Core i3-10100'=$true; 'Core i3-10100E'=$true; 'Core i3-10100F'=$true; 'Core i3-10100T'=$true; 'Core i3-10100TE'=$true; 'Core i3-10100Y'=$true; 'Core i3-10105'=$true; 'Core i3-10105F'=$true; 'Core i3-10105T'=$true; 'Core i3-10110U'=$true; 'Core i3-10110Y'=$true; 'Core i3-10300'=$true; 'Core i3-10300T'=$true; 'Core i3-10305'=$true; 'Core i3-10305T'=$true; 'Core i3-10320'=$true; 'Core i3-10325'=$true; 'Core i3-11100HE'=$true; 'Core i3-1110G4'=$true; 'Core i3-1115G4'=$true; 'Core i3-1115G4E'=$true; 'Core i3-1115GRE'=$true; 'Core i3-1120G4'=$true; 'Core i3-1125G4'=$true; 'Core i3-12100'=$true; 'Core i3-12100E'=$true; 'Core i3-12100F'=$true; 'Core i3-12100T'=$true; 'Core i3-12100TE'=$true; 'Core i3-1210U'=$true; 'Core i3-1215U'=$true; 'Core i3-1215UE'=$true; 'Core i3-1215UL'=$true; 'Core i3-1220P'=$true; 'Core i3-1220PE'=$true; 'Core i3-12300'=$true; 'Core i3-12300HE'=$true; 'Core i3-12300HL'=$true; 'Core i3-12300T'=$true; 'Core i3-1305U'=$true; 'Core i3-13100'=$true; 'Core i3-13100E'=$true; 'Core i3-13100F'=$true; 'Core i3-13100T'=$true; 'Core i3-13100TE'=$true; 'Core i3-1315U'=$true; 'Core i3-1315UE'=$true; 'Core i3-1320PE'=$true; 'Core i3-13300HE'=$true; 'Core i3-14100'=$true; 'Core i3-14100F'=$true; 'Core i3-14100T'=$true; 'Core i3-8100'=$true; 'Core i3-8100B'=$true; 'Core i3-8100H'=$true; 'Core i3-8100T'=$true; 'Core i3-8109U'=$true; 'Core i3-8130U'=$true; 'Core i3-8140U'=$true; 'Core i3-8145U'=$true; 'Core i3-8145UE'=$true; 'Core i3-8300'=$true; 'Core i3-8300T'=$true; 'Core i3-8350K'=$true; 'Core i3-9100'=$true; 'Core i3-9100E'=$true; 'Core i3-9100F'=$true; 'Core i3-9100HL'=$true; 'Core i3-9100T'=$true; 'Core i3-9100TE'=$true; 'Core i3-9300'=$true; 'Core i3-9300T'=$true; 'Core i3-9320'=$true; 'Core i3-9350K'=$true; 'Core i3-9350KF'=$true; 'Core i3-N300'=$true; 'Core i3-N305'=$true;
        'Core i5-10200H'=$true; 'Core i5-10210U'=$true; 'Core i5-10210Y'=$true; 'Core i5-10300H'=$true; 'Core i5-1030G4'=$true; 'Core i5-1030G7'=$true; 'Core i5-10310U'=$true; 'Core i5-10310Y'=$true; 'Core i5-1035G1'=$true; 'Core i5-1035G4'=$true; 'Core i5-1035G7'=$true; 'Core i5-1038NG7'=$true; 'Core i5-10400'=$true; 'Core i5-10400F'=$true; 'Core i5-10400H'=$true; 'Core i5-10400T'=$true; 'Core i5-10500'=$true; 'Core i5-10500E'=$true; 'Core i5-10500H'=$true; 'Core i5-10500T'=$true; 'Core i5-10500TE'=$true; 'Core i5-10505'=$true; 'Core i5-10600'=$true; 'Core i5-10600K'=$true; 'Core i5-10600KF'=$true; 'Core i5-10600T'=$true; 'Core i5-11260H'=$true; 'Core i5-11300H'=$true; 'Core i5-1130G7'=$true; 'Core i5-11320H'=$true; 'Core i5-1135G7'=$true; 'Core i5-11400'=$true; 'Core i5-11400F'=$true; 'Core i5-11400H'=$true; 'Core i5-11400T'=$true; 'Core i5-1140G7'=$true; 'Core i5-1145G7'=$true; 'Core i5-1145G7E'=$true; 'Core i5-1145GRE'=$true; 'Core i5-11500'=$true; 'Core i5-11500H'=$true; 'Core i5-11500HE'=$true; 'Core i5-11500T'=$true; 'Core i5-1155G7'=$true; 'Core i5-11600'=$true; 'Core i5-11600K'=$true; 'Core i5-11600KF'=$true; 'Core i5-11600T'=$true; 'Core i5-1230U'=$true; 'Core i5-1235U'=$true; 'Core i5-1235UL'=$true; 'Core i5-12400'=$true; 'Core i5-12400F'=$true; 'Core i5-12400T'=$true; 'Core i5-1240P'=$true; 'Core i5-1240U'=$true; 'Core i5-12450H'=$true; 'Core i5-12450HX'=$true; 'Core i5-1245U'=$true; 'Core i5-1245UE'=$true; 'Core i5-1245UL'=$true; 'Core i5-12500'=$true; 'Core i5-12500E'=$true; 'Core i5-12500H'=$true; 'Core i5-12500HL'=$true; 'Core i5-12500T'=$true; 'Core i5-12500TE'=$true; 'Core i5-1250P'=$true; 'Core i5-1250PE'=$true; 'Core i5-12600'=$true; 'Core i5-12600H'=$true; 'Core i5-12600HE'=$true; 'Core i5-12600HL'=$true; 'Core i5-12600HX'=$true; 'Core i5-12600K'=$true; 'Core i5-12600KF'=$true; 'Core i5-12600T'=$true; 'Core i5-1334U'=$true; 'Core i5-1335U'=$true; 'Core i5-1335UE'=$true; 'Core i5-13400'=$true; 'Core i5-13400E'=$true; 'Core i5-13400F'=$true; 'Core i5-13400T'=$true; 'Core i5-1340P'=$true; 'Core i5-1340PE'=$true; 'Core i5-13420H'=$true; 'Core i5-13450HX'=$true; 'Core i5-1345U'=$true; 'Core i5-1345UE'=$true; 'Core i5-13490F'=$true; 'Core i5-13500'=$true; 'Core i5-13500E'=$true; 'Core i5-13500H'=$true; 'Core i5-13500HX'=$true; 'Core i5-13500T'=$true; 'Core i5-13500TE'=$true; 'Core i5-13505H'=$true; 'Core i5-1350P'=$true; 'Core i5-1350PE'=$true; 'Core i5-13600'=$true; 'Core i5-13600H'=$true; 'Core i5-13600HE'=$true; 'Core i5-13600HX'=$true; 'Core i5-13600K'=$true; 'Core i5-13600KF'=$true; 'Core i5-13600T'=$true;
        'Core i5-14400'=$true; 'Core i5-14400F'=$true; 'Core i5-14400T'=$true; 'Core i5-14500'=$true; 'Core i5-14500T'=$true; 'Core i5-14600'=$true; 'Core i5-14600K'=$true; 'Core i5-14600KF'=$true; 'Core i5-14600T'=$true;
        'Core i5-8200Y'=$true; 'Core i5-8210Y'=$true; 'Core i5-8250U'=$true; 'Core i5-8257U'=$true; 'Core i5-8259U'=$true; 'Core i5-8260U'=$true; 'Core i5-8265U'=$true; 'Core i5-8269U'=$true; 'Core i5-8279U'=$true; 'Core i5-8300H'=$true; 'Core i5-8305G'=$true; 'Core i5-8310Y'=$true; 'Core i5-8350U'=$true; 'Core i5-8365U'=$true; 'Core i5-8365UE'=$true; 'Core i5-8400'=$true; 'Core i5-8400B'=$true; 'Core i5-8400H'=$true; 'Core i5-8400T'=$true; 'Core i5-8500'=$true; 'Core i5-8500B'=$true; 'Core i5-8500T'=$true; 'Core i5-8600'=$true; 'Core i5-8600K'=$true; 'Core i5-8600T'=$true; 'Core i5-9300H'=$true; 'Core i5-9300HF'=$true; 'Core i5-9400'=$true; 'Core i5-9400F'=$true; 'Core i5-9400H'=$true; 'Core i5-9400T'=$true; 'Core i5-9500'=$true; 'Core i5-9500E'=$true; 'Core i5-9500F'=$true; 'Core i5-9500T'=$true; 'Core i5-9500TE'=$true; 'Core i5-9600'=$true; 'Core i5-9600K'=$true; 'Core i5-9600KF'=$true; 'Core i5-9600T'=$true;
        'Core i7-10510U'=$true; 'Core i7-10510Y'=$true; 'Core i7-1060G7'=$true; 'Core i7-10610U'=$true; 'Core i7-1065G7'=$true; 'Core i7-1068G7'=$true; 'Core i7-1068NG7'=$true; 'Core i7-10700'=$true; 'Core i7-10700E'=$true; 'Core i7-10700F'=$true; 'Core i7-10700K'=$true; 'Core i7-10700KF'=$true; 'Core i7-10700T'=$true; 'Core i7-10700TE'=$true; 'Core i7-10710U'=$true; 'Core i7-10750H'=$true; 'Core i7-10810U'=$true; 'Core i7-10850H'=$true; 'Core i7-10870H'=$true; 'Core i7-10875H'=$true; 'Core i7-11370H'=$true; 'Core i7-11375H'=$true; 'Core i7-11390H'=$true; 'Core i7-11600H'=$true; 'Core i7-1160G7'=$true; 'Core i7-1165G7'=$true; 'Core i7-11700'=$true; 'Core i7-11700F'=$true; 'Core i7-11700K'=$true; 'Core i7-11700KF'=$true; 'Core i7-11700T'=$true; 'Core i7-11800H'=$true; 'Core i7-1180G7'=$true; 'Core i7-11850H'=$true; 'Core i7-11850HE'=$true; 'Core i7-1185G7'=$true; 'Core i7-1185G7E'=$true; 'Core i7-1185GRE'=$true; 'Core i7-1195G7'=$true; 'Core i7-1250U'=$true; 'Core i7-1255U'=$true; 'Core i7-1255UL'=$true; 'Core i7-1260P'=$true; 'Core i7-1260U'=$true; 'Core i7-12650H'=$true; 'Core i7-12650HX'=$true; 'Core i7-1265U'=$true; 'Core i7-1265UE'=$true; 'Core i7-1265UL'=$true; 'Core i7-12700'=$true; 'Core i7-12700E'=$true; 'Core i7-12700F'=$true; 'Core i7-12700H'=$true; 'Core i7-12700HL'=$true; 'Core i7-12700K'=$true; 'Core i7-12700KF'=$true; 'Core i7-12700T'=$true; 'Core i7-12700TE'=$true; 'Core i7-1270P'=$true; 'Core i7-1270PE'=$true; 'Core i7-12800H'=$true; 'Core i7-12800HE'=$true; 'Core i7-12800HL'=$true; 'Core i7-12800HX'=$true; 'Core i7-1280P'=$true; 'Core i7-12850HX'=$true; 'Core i7-1355U'=$true; 'Core i7-1360P'=$true; 'Core i7-13620H'=$true; 'Core i7-13650HX'=$true; 'Core i7-1365U'=$true; 'Core i7-1365UE'=$true; 'Core i7-13700'=$true; 'Core i7-13700E'=$true; 'Core i7-13700F'=$true; 'Core i7-13700H'=$true; 'Core i7-13700HX'=$true; 'Core i7-13700K'=$true; 'Core i7-13700KF'=$true; 'Core i7-13700T'=$true; 'Core i7-13700TE'=$true; 'Core i7-13705H'=$true; 'Core i7-1370P'=$true; 'Core i7-1370PE'=$true; 'Core i7-13790F'=$true; 'Core i7-13800H'=$true; 'Core i7-13800HE'=$true; 'Core i7-13850HX'=$true;
        'Core i7-14700'=$true; 'Core i7-14700F'=$true; 'Core i7-14700K'=$true; 'Core i7-14700KF'=$true; 'Core i7-14700T'=$true;
        'Core i7-7800X'=$true; 'Core i7-7820HQ'=$true; 'Core i7-7820X'=$true; 'Core i7-8086K'=$true; 'Core i7-8500Y'=$true; 'Core i7-8550U'=$true; 'Core i7-8557U'=$true; 'Core i7-8559U'=$true; 'Core i7-8565U'=$true; 'Core i7-8569U'=$true; 'Core i7-8650U'=$true; 'Core i7-8665U'=$true; 'Core i7-8665UE'=$true; 'Core i7-8700'=$true; 'Core i7-8700B'=$true; 'Core i7-8700K'=$true; 'Core i7-8700T'=$true; 'Core i7-8705G'=$true; 'Core i7-8706G'=$true; 'Core i7-8709G'=$true; 'Core i7-8750H'=$true; 'Core i7-8809G'=$true; 'Core i7-8850H'=$true; 'Core i7-9700'=$true; 'Core i7-9700E'=$true; 'Core i7-9700F'=$true; 'Core i7-9700K'=$true; 'Core i7-9700KF'=$true; 'Core i7-9700T'=$true; 'Core i7-9700TE'=$true; 'Core i7-9750H'=$true; 'Core i7-9750HF'=$true; 'Core i7-9800X'=$true; 'Core i7-9850H'=$true; 'Core i7-9850HE'=$true; 'Core i7-9850HL'=$true;
        'Core i9-10850K'=$true; 'Core i9-10885H'=$true; 'Core i9-10900'=$true; 'Core i9-10900E'=$true; 'Core i9-10900F'=$true; 'Core i9-10900K'=$true; 'Core i9-10900KF'=$true; 'Core i9-10900T'=$true; 'Core i9-10900TE'=$true; 'Core i9-10900X'=$true; 'Core i9-10920X'=$true; 'Core i9-10940X'=$true; 'Core i9-10980HK'=$true; 'Core i9-10980XE'=$true;
        'Core i9-11900'=$true; 'Core i9-11900F'=$true; 'Core i9-11900H'=$true; 'Core i9-11900K'=$true; 'Core i9-11900KF'=$true; 'Core i9-11900T'=$true; 'Core i9-11950H'=$true; 'Core i9-11980HK'=$true;
        'Core i9-12900'=$true; 'Core i9-12900E'=$true; 'Core i9-12900F'=$true; 'Core i9-12900H'=$true; 'Core i9-12900HK'=$true; 'Core i9-12900HX'=$true; 'Core i9-12900K'=$true; 'Core i9-12900KF'=$true; 'Core i9-12900KS'=$true; 'Core i9-12900T'=$true; 'Core i9-12900TE'=$true; 'Core i9-12950HX'=$true;
        'Core i9-13900'=$true; 'Core i9-13900E'=$true; 'Core i9-13900F'=$true; 'Core i9-13900H'=$true; 'Core i9-13900HK'=$true; 'Core i9-13900HX'=$true; 'Core i9-13900K'=$true; 'Core i9-13900KF'=$true; 'Core i9-13900KS'=$true; 'Core i9-13900T'=$true; 'Core i9-13900TE'=$true; 'Core i9-13905H'=$true; 'Core i9-13950HX'=$true; 'Core i9-13980HX'=$true;
        'Core i9-14900'=$true; 'Core i9-14900F'=$true; 'Core i9-14900K'=$true; 'Core i9-14900KF'=$true; 'Core i9-14900T'=$true;
        'Core i9-7900X'=$true; 'Core i9-7920X'=$true; 'Core i9-7940X'=$true; 'Core i9-7960X'=$true; 'Core i9-7980XE'=$true; 'Core i9-8950HK'=$true; 'Core i9-9820X'=$true; 'Core i9-9880H'=$true; 'Core i9-9900'=$true; 'Core i9-9900K'=$true; 'Core i9-9900KF'=$true; 'Core i9-9900KS'=$true; 'Core i9-9900T'=$true; 'Core i9-9900X'=$true; 'Core i9-9920X'=$true; 'Core i9-9940X'=$true; 'Core i9-9960X'=$true; 'Core i9-9980HK'=$true; 'Core i9-9980XE'=$true; 'Core m3-8100Y'=$true;
        'Core Ultra 5 125H'=$true; 'Core Ultra 5 125U'=$true; 'Core Ultra 5 134U'=$true; 'Core Ultra 5 135H'=$true; 'Core Ultra 5 135U'=$true; 'Core Ultra 7 155H'=$true; 'Core Ultra 7 155U'=$true; 'Core Ultra 7 164U'=$true; 'Core Ultra 7 165H'=$true; 'Core Ultra 7 165U'=$true; 'Core Ultra 9 185H'=$true;
        'Pentium Gold 4417U'=$true; 'Pentium Gold 4425Y'=$true; 'Pentium Gold 5405U'=$true; 'Pentium Gold 6405U'=$true; 'Pentium Gold 6500Y'=$true; 'Pentium Gold 6805'=$true; 'Pentium Gold 7505'=$true; 'Pentium Gold 8500'=$true; 'Pentium Gold 8505'=$true;
        'Pentium Gold G5400'=$true; 'Pentium Gold G5400T'=$true; 'Pentium Gold G5420'=$true; 'Pentium Gold G5420T'=$true; 'Pentium Gold G5500'=$true; 'Pentium Gold G5500T'=$true; 'Pentium Gold G5600'=$true; 'Pentium Gold G5600E'=$true; 'Pentium Gold G5600T'=$true; 'Pentium Gold G5620'=$true; 'Pentium Gold G6400'=$true; 'Pentium Gold G6400E'=$true; 'Pentium Gold G6400T'=$true; 'Pentium Gold G6400TE'=$true; 'Pentium Gold G6405'=$true; 'Pentium Gold G6405T'=$true; 'Pentium Gold G6500'=$true; 'Pentium Gold G6500T'=$true; 'Pentium Gold G6505'=$true; 'Pentium Gold G6505T'=$true; 'Pentium Gold G6600'=$true; 'Pentium Gold G6605'=$true; 'Pentium Gold G7400'=$true; 'Pentium Gold G7400E'=$true; 'Pentium Gold G7400T'=$true; 'Pentium Gold G7400TE'=$true;
        'Pentium J6426'=$true; 'Pentium N6415'=$true; 'Pentium Silver J5005'=$true; 'Pentium Silver J5040'=$true; 'Pentium Silver N5000'=$true; 'Pentium Silver N5030'=$true; 'Pentium Silver N6000'=$true; 'Pentium Silver N6005'=$true;
        'Processor N100'=$true; 'Processor N200'=$true; 'Processor N50'=$true; 'Processor N95'=$true; 'Processor N97'=$true; 'Processor U300'=$true; 'Processor U300E'=$true;
        'Xeon Bronze 3104'=$true; 'Xeon Bronze 3106'=$true; 'Xeon Bronze 3204'=$true; 'Xeon Bronze 3206R'=$true;
        'Xeon D-1702'=$true; 'Xeon D-1712TR'=$true; 'Xeon D-1713NT'=$true; 'Xeon D-1713NTE'=$true; 'Xeon D-1714'=$true; 'Xeon D-1715TER'=$true; 'Xeon D-1718T'=$true; 'Xeon D-1722NE'=$true; 'Xeon D-1726'=$true; 'Xeon D-1732TE'=$true; 'Xeon D-1733NT'=$true; 'Xeon D-1735TR'=$true; 'Xeon D-1736'=$true; 'Xeon D-1736NT'=$true; 'Xeon D-1739'=$true; 'Xeon D-1746TER'=$true; 'Xeon D-1747NTE'=$true; 'Xeon D-1748TE'=$true; 'Xeon D-1749NT'=$true; 'Xeon D-2712T'=$true; 'Xeon D-2733NT'=$true; 'Xeon D-2738'=$true; 'Xeon D-2752NTE'=$true; 'Xeon D-2752TER'=$true; 'Xeon D-2753NT'=$true; 'Xeon D-2766NT'=$true; 'Xeon D-2775TE'=$true; 'Xeon D-2776NT'=$true; 'Xeon D-2779'=$true; 'Xeon D-2786NTE'=$true; 'Xeon D-2795NT'=$true; 'Xeon D-2796NT'=$true; 'Xeon D-2796TE'=$true; 'Xeon D-2798NT'=$true; 'Xeon D-2799'=$true;
        'Xeon E-2104G'=$true; 'Xeon E-2124'=$true; 'Xeon E-2124G'=$true; 'Xeon E-2126G'=$true; 'Xeon E-2134'=$true; 'Xeon E-2136'=$true; 'Xeon E-2144G'=$true; 'Xeon E-2146G'=$true; 'Xeon E-2174G'=$true; 'Xeon E-2176G'=$true; 'Xeon E-2176M'=$true; 'Xeon E-2186G'=$true; 'Xeon E-2186M'=$true; 'Xeon E-2224'=$true; 'Xeon E-2224G'=$true; 'Xeon E-2226G'=$true; 'Xeon E-2226GE'=$true; 'Xeon E-2234'=$true; 'Xeon E-2236'=$true; 'Xeon E-2244G'=$true; 'Xeon E-2246G'=$true; 'Xeon E-2254ME'=$true; 'Xeon E-2254ML'=$true; 'Xeon E-2274G'=$true; 'Xeon E-2276G'=$true; 'Xeon E-2276M'=$true; 'Xeon E-2276ME'=$true; 'Xeon E-2276ML'=$true; 'Xeon E-2278G'=$true; 'Xeon E-2278GE'=$true; 'Xeon E-2278GEL'=$true; 'Xeon E-2286G'=$true; 'Xeon E-2286M'=$true; 'Xeon E-2288G'=$true;
        'Xeon Gold 5115'=$true; 'Xeon Gold 5118'=$true; 'Xeon Gold 5119T'=$true; 'Xeon Gold 5120'=$true; 'Xeon Gold 5120T'=$true; 'Xeon Gold 5122'=$true; 'Xeon Gold 5215'=$true; 'Xeon Gold 5215L'=$true; 'Xeon Gold 5215M'=$true; 'Xeon Gold 5217'=$true; 'Xeon Gold 5218'=$true; 'Xeon Gold 5218B'=$true; 'Xeon Gold 5218N'=$true; 'Xeon Gold 5218R'=$true; 'Xeon Gold 5218T'=$true; 'Xeon Gold 5220'=$true; 'Xeon Gold 5220R'=$true; 'Xeon Gold 5220S'=$true; 'Xeon Gold 5220T'=$true; 'Xeon Gold 5222'=$true; 'Xeon Gold 5315Y'=$true; 'Xeon Gold 5317'=$true; 'Xeon Gold 5318N'=$true; 'Xeon Gold 5318S'=$true; 'Xeon Gold 5318Y'=$true; 'Xeon Gold 5320'=$true; 'Xeon Gold 5320T'=$true; 'Xeon Gold 5415+'=$true; 'Xeon Gold 5416S'=$true; 'Xeon Gold 5418Y'=$true; 'Xeon Gold 5420+'=$true; 'Xeon Gold 6126'=$true; 'Xeon Gold 6126F'=$true; 'Xeon Gold 6126T'=$true; 'Xeon Gold 6128'=$true; 'Xeon Gold 6130'=$true; 'Xeon Gold 6130F'=$true; 'Xeon Gold 6130T'=$true; 'Xeon Gold 6132'=$true; 'Xeon Gold 6134'=$true; 'Xeon Gold 6136'=$true; 'Xeon Gold 6138'=$true; 'Xeon Gold 6138F'=$true; 'Xeon Gold 6138P'=$true; 'Xeon Gold 6138T'=$true; 'Xeon Gold 6140'=$true; 'Xeon Gold 6142'=$true; 'Xeon Gold 6142F'=$true; 'Xeon Gold 6144'=$true; 'Xeon Gold 6146'=$true; 'Xeon Gold 6148'=$true; 'Xeon Gold 6148F'=$true; 'Xeon Gold 6150'=$true; 'Xeon Gold 6152'=$true; 'Xeon Gold 6154'=$true; 'Xeon Gold 6208U'=$true; 'Xeon Gold 6209U'=$true; 'Xeon Gold 6210U'=$true; 'Xeon Gold 6212U'=$true; 'Xeon Gold 6222V'=$true; 'Xeon Gold 6226'=$true; 'Xeon Gold 6226R'=$true; 'Xeon Gold 6230'=$true; 'Xeon Gold 6230N'=$true; 'Xeon Gold 6230R'=$true; 'Xeon Gold 6230T'=$true; 'Xeon Gold 6234'=$true; 'Xeon Gold 6238'=$true; 'Xeon Gold 6238L'=$true; 'Xeon Gold 6238M'=$true; 'Xeon Gold 6238R'=$true; 'Xeon Gold 6238T'=$true; 'Xeon Gold 6240'=$true; 'Xeon Gold 6240L'=$true; 'Xeon Gold 6240M'=$true; 'Xeon Gold 6240R'=$true; 'Xeon Gold 6240Y'=$true; 'Xeon Gold 6242'=$true; 'Xeon Gold 6242R'=$true; 'Xeon Gold 6244'=$true; 'Xeon Gold 6246'=$true; 'Xeon Gold 6246R'=$true; 'Xeon Gold 6248'=$true; 'Xeon Gold 6248R'=$true; 'Xeon Gold 6250'=$true; 'Xeon Gold 6250L'=$true; 'Xeon Gold 6252'=$true; 'Xeon Gold 6252N'=$true; 'Xeon Gold 6254'=$true; 'Xeon Gold 6256'=$true; 'Xeon Gold 6258R'=$true; 'Xeon Gold 6262V'=$true; 'Xeon Gold 6312U'=$true; 'Xeon Gold 6314U'=$true; 'Xeon Gold 6326'=$true; 'Xeon Gold 6330'=$true; 'Xeon Gold 6330N'=$true; 'Xeon Gold 6334'=$true; 'Xeon Gold 6336Y'=$true; 'Xeon Gold 6338'=$true; 'Xeon Gold 6338N'=$true; 'Xeon Gold 6338T'=$true; 'Xeon Gold 6342'=$true; 'Xeon Gold 6346'=$true; 'Xeon Gold 6348'=$true; 'Xeon Gold 6354'=$true; 'Xeon Gold 6416H'=$true; 'Xeon Gold 6418H'=$true; 'Xeon Gold 6430'=$true; 'Xeon Gold 6438Y+'=$true; 'Xeon Gold 6442Y'=$true;
        'Xeon Platinum 8153'=$true; 'Xeon Platinum 8156'=$true; 'Xeon Platinum 8158'=$true; 'Xeon Platinum 8160'=$true; 'Xeon Platinum 8160F'=$true; 'Xeon Platinum 8160T'=$true; 'Xeon Platinum 8164'=$true; 'Xeon Platinum 8168'=$true; 'Xeon Platinum 8170'=$true; 'Xeon Platinum 8171M'=$true; 'Xeon Platinum 8176'=$true; 'Xeon Platinum 8176F'=$true; 'Xeon Platinum 8180'=$true; 'Xeon Platinum 8253'=$true; 'Xeon Platinum 8256'=$true; 'Xeon Platinum 8260'=$true; 'Xeon Platinum 8260L'=$true; 'Xeon Platinum 8260M'=$true; 'Xeon Platinum 8260Y'=$true; 'Xeon Platinum 8268'=$true; 'Xeon Platinum 8270'=$true; 'Xeon Platinum 8272CL'=$true; 'Xeon Platinum 8276'=$true; 'Xeon Platinum 8276L'=$true; 'Xeon Platinum 8276M'=$true; 'Xeon Platinum 8280'=$true; 'Xeon Platinum 8280L'=$true; 'Xeon Platinum 8280M'=$true; 'Xeon Platinum 8351N'=$true; 'Xeon Platinum 8352M'=$true; 'Xeon Platinum 8352S'=$true; 'Xeon Platinum 8352V'=$true; 'Xeon Platinum 8352Y'=$true; 'Xeon Platinum 8358'=$true; 'Xeon Platinum 8358P'=$true; 'Xeon Platinum 8360Y'=$true; 'Xeon Platinum 8362'=$true; 'Xeon Platinum 8368'=$true; 'Xeon Platinum 8368Q'=$true; 'Xeon Platinum 8380'=$true; 'Xeon Platinum 8452Y'=$true; 'Xeon Platinum 8460Y+'=$true; 'Xeon Platinum 8468'=$true; 'Xeon Platinum 8470'=$true; 'Xeon Platinum 8480+'=$true; 'Xeon Platinum 8490H'=$true; 'Xeon Platinum 9221'=$true; 'Xeon Platinum 9222'=$true; 'Xeon Platinum 9242'=$true; 'Xeon Platinum 9282'=$true;
        'Xeon Silver 4108'=$true; 'Xeon Silver 4109T'=$true; 'Xeon Silver 4110'=$true; 'Xeon Silver 4112'=$true; 'Xeon Silver 4114'=$true; 'Xeon Silver 4114T'=$true; 'Xeon Silver 4116'=$true; 'Xeon Silver 4116T'=$true; 'Xeon Silver 4208'=$true; 'Xeon Silver 4209T'=$true; 'Xeon Silver 4210'=$true; 'Xeon Silver 4210R'=$true; 'Xeon Silver 4210T'=$true; 'Xeon Silver 4214'=$true; 'Xeon Silver 4214R'=$true; 'Xeon Silver 4214Y'=$true; 'Xeon Silver 4215'=$true; 'Xeon Silver 4215R'=$true; 'Xeon Silver 4216'=$true; 'Xeon Silver 4309Y'=$true; 'Xeon Silver 4310'=$true; 'Xeon Silver 4310T'=$true; 'Xeon Silver 4314'=$true; 'Xeon Silver 4316'=$true; 'Xeon Silver 4410T'=$true; 'Xeon Silver 4410Y'=$true; 'Xeon Silver 4416+'=$true;
        'Xeon W-10855M'=$true; 'Xeon W-10885M'=$true; 'Xeon W-11055M'=$true; 'Xeon W-11155MLE'=$true; 'Xeon W-11155MRE'=$true; 'Xeon W-11555MLE'=$true; 'Xeon W-11555MRE'=$true; 'Xeon W-11855M'=$true; 'Xeon W-11865MLE'=$true; 'Xeon W-11865MRE'=$true; 'Xeon W-11955M'=$true; 'Xeon W-1250'=$true; 'Xeon W-1250E'=$true; 'Xeon W-1250P'=$true; 'Xeon W-1250TE'=$true; 'Xeon W-1270'=$true; 'Xeon W-1270E'=$true; 'Xeon W-1270P'=$true; 'Xeon W-1270TE'=$true; 'Xeon W-1290'=$true; 'Xeon W-1290E'=$true; 'Xeon W-1290P'=$true; 'Xeon W-1290T'=$true; 'Xeon W-1290TE'=$true; 'Xeon W-1350'=$true; 'Xeon W-1350P'=$true; 'Xeon W-1370'=$true; 'Xeon W-1370P'=$true; 'Xeon W-1390'=$true; 'Xeon W-1390P'=$true; 'Xeon W-1390T'=$true; 'Xeon W-2102'=$true; 'Xeon W-2104'=$true; 'Xeon W-2123'=$true; 'Xeon W-2125'=$true; 'Xeon W-2133'=$true; 'Xeon W-2135'=$true; 'Xeon W-2145'=$true; 'Xeon W-2155'=$true; 'Xeon W-2175'=$true; 'Xeon W-2195'=$true; 'Xeon W-2223'=$true; 'Xeon W-2225'=$true; 'Xeon W-2235'=$true; 'Xeon W-2245'=$true; 'Xeon W-2255'=$true; 'Xeon W-2265'=$true; 'Xeon W-2275'=$true; 'Xeon W-2295'=$true;
        'Xeon W-3175X'=$true; 'Xeon W-3223'=$true; 'Xeon W-3225'=$true; 'Xeon W-3235'=$true; 'Xeon W-3245'=$true; 'Xeon W-3245M'=$true; 'Xeon W-3265'=$true; 'Xeon W-3265M'=$true; 'Xeon W-3275'=$true; 'Xeon W-3275M'=$true; 'Xeon W-3323'=$true; 'Xeon W-3335'=$true; 'Xeon W-3345'=$true; 'Xeon W-3365'=$true; 'Xeon W-3375' = $true;
        'Xeon W3-2423'=$true; 'Xeon W3-2425'=$true; 'Xeon W3-2435'=$true; 'Xeon W5-2445'=$true; 'Xeon W5-2455X'=$true; 'Xeon W5-2465X'=$true; 'Xeon W5-3423'=$true; 'Xeon W5-3425'=$true; 'Xeon W5-3433'=$true; 'Xeon W5-3435X'=$true; 'Xeon W7-2475X'=$true; 'Xeon W7-2495X'=$true; 'Xeon W7-3445'=$true; 'Xeon W7-3455'=$true; 'Xeon W7-3465X'=$true; 'Xeon W9-3475X'=$true; 'Xeon W9-3495X'=$true
    }
    #endregion
    
    # --- Start of Compatibility Check ---
    $results = [ordered]@{
        OS64Bit                 = $false
        SecureBootEnabled       = $false
        TPM2Present             = $false
        MemoryGB                = 0
        FreeSpaceGB             = 0
        CpuVbsCompatible        = $false
        IsWindows11             = $false
        AllPassed               = $true
        Details                 = @()
    }

    try {
        # Check if this is a PAN/CEPH/3D imaging capture machine (informational only)
        if (Test-ImagingMachine) {
            $results.Details += "System detected as PAN/CEPH/3D imaging capture machine (Computer: $env:COMPUTERNAME)"
        }
      
        # Check if already running Windows 11
        $osInfo = Get-CimInstance Win32_OperatingSystem
        $osVersion = [System.Environment]::OSVersion.Version
        $buildNumber = $osInfo.BuildNumber
        
        # Windows 11 has build numbers starting from 22000
        if ([int]$buildNumber -ge 22000) {
            $results.IsWindows11 = $true
            $results.AllPassed = $false
            $results.Details += "System is already running Windows 11 (Build: $buildNumber)"
            return $results
        }
        
        # Check if running Windows 10 LTSC (Long Term Servicing Channel)
        $osCaption = $osInfo.Caption
        if ($osCaption -match "LTSC|Long Term Servicing") {
            $results.AllPassed = $false
            $results.Details += "System excluded: Running Windows 10 LTSC edition with extended support"
            return $results
        }
        
       # OS Architecture
        $arch = $osInfo.OSArchitecture
        $results.OS64Bit = $arch -match '64-bit'
        if (-not $results.OS64Bit) {
            $results.AllPassed = $false
            $results.Details += 'OS is not 64-bit'
        }

        # Secure Boot (Informational)
        try {
            $sb = Confirm-SecureBootUEFI
            $results.SecureBootEnabled = $sb
            if (-not $sb) {
                $results.Details += 'Secure Boot is disabled (Informational)'
            }
        }
        catch {
            $results.Details += 'Secure Boot check unavailable (may require admin rights)'
        }

        # TPM 2.0
        try {
            $win32tpm = Get-CimInstance -Namespace root\cimv2\security\microsofttpm -Class Win32_Tpm -ErrorAction Stop
            if ($null -eq $win32tpm) {
                $results.AllPassed = $false
                $results.Details += 'No TPM module detected'
            }
            else {
                $rawVersion = ($win32tpm.SpecVersion -split ',')[0].Trim()
                try { $version = [version]$rawVersion } catch { $results.AllPassed = $false; $results.Details += "Invalid TPM version format: $rawVersion"; $version = [version]'0.0' }
                
                if ($version -lt [version]'2.0') {
                    $results.AllPassed = $false
                    $results.Details += "Unsupported TPM version: $rawVersion"
                }
                if (-not $win32tpm.IsEnabled_InitialValue) {
                    $results.AllPassed = $false
                    $results.Details += 'TPM not enabled in firmware'
                }
                if (-not $win32tpm.IsActivated_InitialValue) {
                    $results.AllPassed = $false
                    $results.Details += 'TPM not activated (owned)'
                }
                if ($version -ge [version]'2.0' -and $win32tpm.IsEnabled_InitialValue -and $win32tpm.IsActivated_InitialValue) {
                    $results.TPM2Present = $true
                }
            }
        }
        catch {
            $results.AllPassed = $false
            $results.Details += "TPM check failed: $($_.Exception.Message)"
        }

        # Memory
        $mem = Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum
        $results.MemoryGB = [math]::Round($mem.Sum / 1GB, 2)
        if ($results.MemoryGB -lt 4) {
            $results.AllPassed = $false
            $results.Details += "Insufficient RAM: $($results.MemoryGB) GB (requires 4+ GB minimum)"
        } elseif ($results.MemoryGB -lt 15) {
            $results.Details += "RAM notice: $($results.MemoryGB) GB is under the recommended 15 GB"
        }

        # Disk Space (Informational)
        $sys = Get-CimInstance Win32_OperatingSystem
        $free = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($sys.SystemDrive)'").FreeSpace
        $results.FreeSpaceGB = [math]::Round($free / 1GB, 2)
        if ($results.FreeSpaceGB -lt 64) {
            $results.Details += "Warning: Insufficient free disk space: $($results.FreeSpaceGB) GB"
        }

        # ===================================================================
        # CPU COMPATIBILITY LOGIC
        # ===================================================================
        $cpuInfo = Get-CimInstance Win32_Processor | Select-Object -First 1
        $manu = $cpuInfo.Manufacturer.Trim()
        $name = $cpuInfo.Name

        if ($manu -eq 'GenuineIntel') {
            # Step 1: Check if the CPU name contains a model from the master list.
            $foundOnList = $false
            # Clean the CPU name from WMI to remove registered/trademark symbols and extra spaces for easier matching.
            $cleanName = $name -replace '\(R\)|\(TM\)|\[\d\]', '' -replace '\s+', ' '
            
            foreach ($modelKey in $SupportedIntelHashtable.Keys) {
                # This regex looks for the exact model key as a whole word.
                $pattern = "(\s|^)$([regex]::Escape($modelKey))(\s|$)"
                if ($cleanName -match $pattern) {
                    $foundOnList = $true
                    break 
                }
            }

            if ($foundOnList) {
                $results.CpuVbsCompatible = $true
                $results.Details += "CPU found on explicit support list."
            }
            else {
                # Step 2: If not found on the list, use the fallback logic.
                $results.Details += "CPU not on list, using fallback logic."
                try {
                    $deviceGuardInfo = Get-CimInstance -Namespace ROOT\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
                    if ($deviceGuardInfo.AvailableSecurityProperties -contains 5) {
                        # Fallback Step 2a: Hardware feature is present. Now, use naming scheme as a final sanity check.
                        $fallbackPassed = $false
                        if ($name -match '[iI]\d+-(\d{4,5})') { # This regex now correctly finds 4 or 5 digit model numbers.
                            $modelString = $Matches[1]
                            $generation = 0
                            if ($modelString.StartsWith('1')) {
                                $generation = [int]$modelString.Substring(0, 2)
                            } else {
                                $generation = [int]$modelString.Substring(0, 1)
                            }
                            
                            if ($generation -ge 8) {
                                $fallbackPassed = $true
                                $results.Details += "CPU passed fallback check (>=8th Gen)."
                            } else {
                                $results.Details += "CPU has hardware features but is an older Gen model (<8th Gen)."
                            }
                        }
                        elseif ($name -match 'Xeon') { # Fallback for future Xeon models
                             if ($name -match 'Xeon\(R\) (Platinum|Gold|Silver|Bronze)\s+(\d{4})') {
                                $modelNumber = $Matches[2]; $generationDigit = [int]$modelNumber.Substring(1, 1)
                                if ($generationDigit -ge 3) { $fallbackPassed = $true; $results.Details += "CPU passed fallback check (>=3rd Gen Scalable Xeon)." }
                                else { $results.Details += "CPU failed fallback check (<3rd Gen Scalable Xeon)." }
                            }
                            elseif ($name -match 'Xeon\(R\) (W-|W\d\s)') {
                                $fallbackPassed = $true; $results.Details += "CPU passed fallback check (Xeon W Family)."
                            }
                        }
                        # Add other potential future-proof checks here if necessary

                        if ($fallbackPassed) {
                            $results.CpuVbsCompatible = $true
                        }

                    } else {
                        $results.Details += "CPU lacks required hardware security features (MBEC)."
                    }
                }
                catch {
                    $results.Details += "Device Guard check failed. OS may be too old."
                }
            }
        }
        # --- AMD and ARM LOGIC (Remains Rule-Based) ---
        elseif ($manu -eq 'AuthenticAMD') {
            if ($name -match 'Ryzen\s*\d+\s*(\d{4})') {
                $model = [int]$Matches[1]
                if ($model -ge 2000) { $results.CpuVbsCompatible = $true } else { $results.Details += "Unsupported AMD Ryzen generation." }
            } else { $results.Details += "Unable to parse or unsupported AMD CPU model." }
        }
        elseif ($cpuInfo.Architecture -eq 9) { # ARM64
             if ($name -match 'Snapdragon.*(7c|8c|8cx|850)|Microsoft SQ[123]') {
                $results.CpuVbsCompatible = $true
            } else { $results.Details += "Unsupported ARM CPU model." }
        }
        else {
            $results.Details += "Unsupported CPU manufacturer: $manu"
        }

        if (-not $results.CpuVbsCompatible) {
            $results.AllPassed = $false
        }
        # ===================================================================
        # END OF CPU LOGIC BLOCK
        # ===================================================================

        return $results
    }
    catch {
        Write-Error "Error checking compatibility: $_"
        exit 1
    }
}

# Run the check and display results
$compat = Check-Windows11Compatibility

$Compatible = if ($compat.IsWindows11) { 'ALREADY_WIN11' } elseif ($compat.AllPassed) { 'YES' } else { 'NO' }$DetailString = if ($compat.Details.Count -gt 0) { ($compat.Details | Where-Object {$_}) -join '; ' } else { 'All checks passed' }

if (Get-Command 'Ninja-Property-Set' -ErrorAction SilentlyContinue) {
    Ninja-Property-Set -Name 'windows11upgrade' -Value $Compatible
    Ninja-Property-Set -Name 'windows11UpgradeDetails' -Value $DetailString
}

if ($compat.IsWindows11) {
    Write-Host "Overall Result: ALREADY RUNNING WINDOWS 11"
    Write-Host ""
    Write-Host "This system is already running Windows 11."
    Write-Host "Build Number: $((Get-CimInstance Win32_OperatingSystem).BuildNumber)"
} else {
    Write-Host "Overall Result: $Compatible"
    Write-Host ""
    Write-Host "CRITICAL CHECKS:"
    Write-Host " - 64-bit OS: $($compat.OS64Bit)"
    Write-Host " - TPM 2.0 Ready: $($compat.TPM2Present)"
    Write-Host " - Memory (RAM): $($compat.MemoryGB) GB"
    Write-Host " - CPU Hardware & Policy Compatible: $($compat.CpuVbsCompatible)"
    Write-Host ""
    Write-Host "INFORMATIONAL CHECKS:"
    Write-Host " - System Drive Free Space: $($compat.FreeSpaceGB) GB"
    Write-Host " - Secure Boot Enabled: $($compat.SecureBootEnabled)"
    Write-Host ""
}

if ($compat.Details.Count -gt 0) {
    Write-Host "Details:"
    $compat.Details | Where-Object {$_} | ForEach-Object { Write-Host " - $_" }
}

Write-Host "----------------------------------------"

# Exit with the appropriate code
if ($compat.IsWindows11) {
    # Already on Windows 11 - exit 100 (no upgrade needed)
    exit 100
} else {
    # Check if this is a PAN/CEPH/3D imaging machine (always exit 3 when detected)
    $isImagingMachine = $false
    foreach ($detail in $compat.Details) {
        if ($detail -match "System detected as PAN/CEPH/3D imaging capture machine") {
            $isImagingMachine = $true
            break
        }
    }
    
    if ($isImagingMachine) {
        # PAN/CEPH imaging machine detected - always exit 3
        exit 3
    }
}

if (-not $compat.AllPassed) {
    # Analyze failure types to determine specific exit codes
    $hasRAMIssue = $false
    $hasSpaceIssue = $false
    $hasOtherIssues = $false
    
    foreach ($detail in $compat.Details) {
        if ($detail -match "Insufficient RAM:.*GB \(requires 4\+ GB minimum\)") {
            $hasRAMIssue = $true
        } elseif ($detail -match "Warning: Insufficient free disk space") {
            $hasSpaceIssue = $true
        } elseif ($detail -match "Secure Boot is disabled \(Informational\)" -or 
                  $detail -match "System detected as PAN/CEPH/3D imaging capture machine" -or
                  $detail -match "RAM notice:") {
            # Skip informational messages
            continue
        } elseif ($detail -ne "All checks passed") {
            # Any other failure
            $hasOtherIssues = $true
        }
    }
    
    # Count how many failure types we have
    $failureTypes = 0
    if ($hasRAMIssue) { $failureTypes++ }
    if ($hasSpaceIssue) { $failureTypes++ }
    if ($hasOtherIssues) { $failureTypes++ }
    
    # Determine exit code based on specific failure combinations
    if ($failureTypes -ge 3) {
        # All failure types present - exit 6
        exit 6
    } elseif ($failureTypes -ge 2) {
        # 2-3 failure types present - exit 5
        exit 5
    } elseif ($hasRAMIssue) {
        # Only RAM issue - exit 2
        exit 2
    } elseif ($hasSpaceIssue) {
        # Only space issue - exit 4
        exit 4
    } else {
        # Other single failure - exit 2 (general failure)
        exit 2
    }
} else {
    # All checks passed - exit 0 (ready to upgrade)
    exit 0
}