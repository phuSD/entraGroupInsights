$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$private = Get-ChildItem -Path (Join-Path $here 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue
$public  = Get-ChildItem -Path (Join-Path $here 'Public')  -Filter '*.ps1' -ErrorAction SilentlyContinue

foreach ($file in @($private) + @($public)) {
    try {
        . $file.FullName
    }
    catch {
        Write-Error -Message "Failed to dot-source $($file.FullName): $_"
    }
}

Export-ModuleMember -Function $public.BaseName
