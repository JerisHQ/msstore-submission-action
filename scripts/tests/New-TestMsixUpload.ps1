# Writes a fake .msixupload for tests: a zip holding one .msix, itself a zip
# holding only an AppxManifest.xml with the given identity. Not a valid
# package (nothing is signed); enough for Get-StorePackage, which reads only
# the manifest identity. Prints the full path of the file it wrote.
param(
  [Parameter(Mandatory)][string]$Dir,
  [string]$Name = 'Contoso.ExampleApp',
  [string]$Publisher = 'CN=00000000-0000-0000-0000-000000000000',
  [string]$Version = '1.2.3.0',
  [string]$FileName = ''
)
$ErrorActionPreference = 'Stop'
if (-not $FileName) { $FileName = "ExampleApp-$Version-x64.msixupload" }
New-Item -ItemType Directory -Force $Dir | Out-Null
$work = Join-Path ([IO.Path]::GetTempPath()) ('msix-make-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work | Out-Null
try {
  $xml = [System.Xml.XmlDocument]::new()
  $ns = 'http://schemas.microsoft.com/appx/manifest/foundation/windows10'
  $pkg = $xml.AppendChild($xml.CreateElement('Package', $ns))
  $id = $pkg.AppendChild($xml.CreateElement('Identity', $ns))
  $id.SetAttribute('Name', $Name); $id.SetAttribute('Publisher', $Publisher)
  $id.SetAttribute('Version', $Version); $id.SetAttribute('ProcessorArchitecture', 'x64')
  $manifest = Join-Path $work 'AppxManifest.xml'
  $xml.Save($manifest)
  Compress-Archive -LiteralPath $manifest -DestinationPath (Join-Path $work 'inner.zip')
  Move-Item -LiteralPath (Join-Path $work 'inner.zip') (Join-Path $work 'ExampleApp.msix')
  Compress-Archive -LiteralPath (Join-Path $work 'ExampleApp.msix') -DestinationPath (Join-Path $work 'outer.zip')
  $dest = Join-Path $Dir $FileName
  Move-Item -LiteralPath (Join-Path $work 'outer.zip') $dest -Force
  (Resolve-Path -LiteralPath $dest).Path
} finally {
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
