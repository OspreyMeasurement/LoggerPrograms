<#
Offline protocol fixtures and CR350 compilation checks. No logger connection.
The byte-copy fixture checker extracts the decoder operations and field
indexes from the CRBasic source; it is NOT a CRBasic runtime simulator.
Compiler variants / reports are retained in a unique temporary directory.
#>
[CmdletBinding()]
param(
    [string]$Compiler = 'C:\Campbellsci\Lib\Compilers\cr350comp.exe'
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $repoRoot 'Campbell Scientific\CR350_OTS_MultiCh.CRB'
$source = [IO.File]::ReadAllText($sourcePath)

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

# Drop comments before extracting executable source; fail closed if the small
# decoder gains operations this fixture checker does not understand.
$code = (($source -split '\r?\n' | ForEach-Object { ($_ -split "'", 2)[0] }) -join "`n")
$decoder = [regex]::Match($code, '(?ms)^Sub DecodeOTSFloat\([^\n]+\)\s*\n(.*?)^EndSub').Groups[1].Value
$moves = @()
foreach ($line in ($decoder -split '\n')) {
    if (-not $line.Trim()) { continue }
    $operation = [regex]::Match($line.Trim(), '^MoveBytes\(Value,(\d+),(LowWord|HighWord),(\d+),(\d+)\)$')
    Assert-True $operation.Success "Unsupported decoder instruction: $line"
    $moves += [pscustomobject]@{
        Dest = [int]$operation.Groups[1].Value
        Source = $operation.Groups[2].Value
        Offset = [int]$operation.Groups[3].Value
        Count = [int]$operation.Groups[4].Value
    }
}
Assert-True ($moves.Count -eq 2) 'Expected two word copies in DecodeOTSFloat.'
Assert-True ([BitConverter]::IsLittleEndian) 'Fixtures require a little-endian host, matching CR350 numeric memory.'
$mappings = [regex]::Matches($code, 'Call DecodeOTSFloat\(RawRegisters\((\d+)\),RawRegisters\((\d+)\),(OTS_\w+)\(ch,i\)\)')
Assert-True ($mappings.Count -eq 8) 'Expected eight OTS float mappings.'
$statusIndex = [regex]::Match($code, 'OTS_Status\(ch,i\)\s*=\s*RawRegisters\((\d+)\)')
Assert-True $statusIndex.Success 'Missing sensor status mapping.'
Assert-True ($code -match 'If OTS_Status\(ch,i\) = 0 Then OTS_Valid\(ch,i\) = 1') 'Review changed validity rule.'
Assert-True ($code -match 'ModbusClient\(OTS_ResultCode\(ch,i\),ModbusPort,BaudRate,i,3,RawRegisters\(\),257,24,MODBUS_TRIES,MODBUS_TIMEOUT_10MS,3\)') 'Review changed Modbus request.'

# Independent protocol fixture: physical registers from the OTS firmware;
# literal IEEE-754 bit patterns include sign bits, zero, and nonzero low words.
$fields = @(
    @{ Name='OTS_V';     Register=258; Hex='41480000' }, # 12.5
    @{ Name='OTS_DegC';  Register=260; Hex='C0A80000' }, # -5.25
    @{ Name='OTS_X';     Register=262; Hex='3F800000' }, # 1.0
    @{ Name='OTS_Y';     Register=264; Hex='BF800000' }, # -1.0
    @{ Name='OTS_Z';     Register=266; Hex='80000000' }, # negative zero
    @{ Name='OTS_Roll';  Register=268; Hex='40490FDB' }, # float32 pi
    @{ Name='OTS_Pitch'; Register=270; Hex='00000000' }, # positive zero
    @{ Name='OTS_Yaw';   Register=272; Hex='40C90FDB' }  # float32 2*pi
)
$fixtureCount = 0
foreach ($status in @(0,1,2,3,4,5,6,32768,65535)) {
    # Zero-based host array, with deliberate nonzero padding outside OTS data.
    $registers = [int[]]::new(24)
    for ($index = 0; $index -lt 24; $index++) { $registers[$index] = 0xA55A }
    foreach ($field in $fields) {
        $registers[$field.Register - 256] = [Convert]::ToInt32($field.Hex.Substring(0,4),16)
        $registers[$field.Register - 255] = [Convert]::ToInt32($field.Hex.Substring(4,4),16)
    }
    $registers[23] = $status
    $seen = @{}
    foreach ($mapping in $mappings) {
        $name = $mapping.Groups[3].Value
        $seen[$name] = $true
        $field = @($fields | Where-Object { $_.Name -eq $name })
        Assert-True ($field.Count -eq 1) "Unknown destination: $name"
        $wordBytes = @{
            HighWord = [BitConverter]::GetBytes($registers[[int]$mapping.Groups[1].Value - 1])
            LowWord = [BitConverter]::GetBytes($registers[[int]$mapping.Groups[2].Value - 1])
        }
        $dest = [byte[]]::new(4)
        foreach ($move in $moves) {
            [Array]::Copy($wordBytes[$move.Source],$move.Offset,$dest,$move.Dest,$move.Count)
        }
        $actualBits = [BitConverter]::ToUInt32($dest,0)
        $expectedBits = [Convert]::ToUInt32($field[0].Hex,16)
        Assert-True ($actualBits -eq $expectedBits) "Wrong float bits for $name / status $status"
    }
    Assert-True ($seen.Count -eq 8) 'Duplicate float destination.'
    Assert-True ($registers[[int]$statusIndex.Groups[1].Value - 1] -eq $status) "Wrong status word: $status"
    $fixtureCount++
}
Write-Output "PASS: $fixtureCount register fixtures (8 floats each; status 0..6 and unsigned boundaries)."

Assert-True (Test-Path -LiteralPath $Compiler -PathType Leaf) "CR350 compiler not found: $Compiler"
$outputDir = Join-Path ([IO.Path]::GetTempPath()) ('ots-validation-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($outputDir)

function Set-Constant([string]$Text, [string]$Name, [int]$Value) {
    $pattern = '(?m)^Const ' + [regex]::Escape($Name) + ' = \d+'
    Assert-True ([regex]::Matches($Text,$pattern).Count -eq 1) "Missing constant: $Name"
    return [regex]::Replace($Text,$pattern,('Const ' + $Name + ' = ' + $Value))
}

function Set-ChannelCount([string]$Text, [int]$Channel, [int]$Count) {
    $pattern = '(?m)(Case ' + $Channel + '\s*\n\s*ArrayName\(ConfigCh\) = "[^"\r\n]*"\s*\n\s*SensorCount\(ConfigCh\) = )-?\d+'
    Assert-True ([regex]::Matches($Text,$pattern).Count -eq 1) "Missing channel case: $Channel"
    $replacement = '${1}' + $Count
    return [regex]::Replace($Text,$pattern,$replacement)
}

$one = Set-Constant $source 'NUM_CHANNELS' 1
$one = Set-Constant $one 'MAX_SENSORS' 1
$one = Set-ChannelCount $one 1 1
$sixteen = Set-Constant $source 'NUM_CHANNELS' 16
for ($channel = 1; $channel -lt 16; $channel++) { $sixteen = Set-ChannelCount $sixteen $channel 0 }
$sixteen = Set-ChannelCount $sixteen 16 10
$capacity = Set-ChannelCount $source 1 10
$invalidHigh = Set-ChannelCount $source 1 11
$invalidLow = Set-ChannelCount $source 1 -1
$allDisabled = $source
for ($channel = 1; $channel -le 4; $channel++) { $allDisabled = Set-ChannelCount $allDisabled $channel 0 }
$addressBoundary = Set-Constant $one 'MAX_SENSORS' 247
$addressBoundary = Set-ChannelCount $addressBoundary 1 247
$variants = [ordered]@{
    default_unequal_sparse = $source
    single_sensor = $one
    channel_16_only = $sixteen
    exact_capacity = $capacity
    invalid_count_high = $invalidHigh
    invalid_count_negative = $invalidLow
    all_disabled = $allDisabled
    address_247 = $addressBoundary
    interval_1_minute = (Set-Constant $source 'MEAS_INTERVAL_MIN' 1)
}

foreach ($variant in $variants.GetEnumerator()) {
    $variantDir = Join-Path $outputDir $variant.Key
    [void][IO.Directory]::CreateDirectory($variantDir)
    $variantPath = Join-Path $variantDir ($variant.Key + '.CRB')
    [IO.File]::WriteAllText($variantPath,$variant.Value,[Text.Encoding]::ASCII)
    # Campbell writes CR350cmple.xxx to the working directory. Keep all
    # compiler side effects out of the repository and existing examples.
    Push-Location -LiteralPath $variantDir
    try {
        $result = (& $Compiler $variantPath 2>&1 | Out-String)
        $compilerExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    [IO.File]::WriteAllText((Join-Path $variantDir 'compile.txt'),$result)
    Assert-True ($compilerExit -eq 0 -and $result -match 'Compiled OK') "Compile failed: $($variant.Key)`n$result"
    Write-Output "PASS: compile $($variant.Key)"
}
Write-Output "Compiler artifacts: $outputDir"
Write-Output 'Runtime bounds, mux sequencing, fault handling and timing still require the documented bench checks.'
