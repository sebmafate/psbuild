﻿[cmdletbinding(DefaultParameterSetName='build')]
param(
    [Parameter(ParameterSetName='build',Position=0)]
    [switch]$build,
    
    [Parameter(ParameterSetName='updateversion',Position=0)]
    [switch]$updateversion,

    [Parameter(ParameterSetName='getversion',Position=0)]
    [switch]$getversion,

    # build parameters
    [Parameter(ParameterSetName='build',Position=1)]
    [switch]$CleanOutputFolder,

    [Parameter(ParameterSetName='build',Position=2)]
    [switch]$publishToNuget,

    [Parameter(ParameterSetName='build',Position=3)]
    [string]$nugetApiKey = ($env:NuGetApiKey),

    # updateversion parameters
    [Parameter(ParameterSetName='updateversion',Position=1,Mandatory=$true)]
    [string]$newversion,

    [Parameter(ParameterSetName='updateversion',Position=2)]
    [string]$oldversion
)
 
 function Get-ScriptDirectory
{
    $Invocation = (Get-Variable MyInvocation -Scope 1).Value
    Split-Path $Invocation.MyCommand.Path
}

$scriptDir = ((Get-ScriptDirectory) + "\")

<#
.SYNOPSIS  
	This will return the path to msbuild.exe. If the path has not yet been set
	then the highest installed version of msbuild.exe will be returned.
#>
function Get-MSBuildExe{
    [cmdletbinding()]
        param()
        process{
	    $path = $script:defaultMSBuildPath

	    if(!$path){
	        $path =  Get-ChildItem "hklm:\SOFTWARE\Microsoft\MSBuild\ToolsVersions\" | 
				        Sort-Object {[double]$_.PSChildName} -Descending | 
				        Select-Object -First 1 | 
				        Get-ItemProperty -Name MSBuildToolsPath |
				        Select -ExpandProperty MSBuildToolsPath
        
            $path = (Join-Path -Path $path -ChildPath 'msbuild.exe')
	    }

        return Get-Item $path
    }
}

<#
.SYNOPSIS
    If nuget is in the tools
    folder then it will be downloaded there.
#>
function Get-Nuget(){
    [cmdletbinding()]
    param(
        $toolsDir = ("$env:LOCALAPPDATA\LigerShark\tools\"),

        $nugetDownloadUrl = 'http://nuget.org/nuget.exe'
    )
    process{
        $nugetDestPath = Join-Path -Path $toolsDir -ChildPath nuget.exe
        
        if(!(Test-Path $nugetDestPath)){
            'Downloading nuget.exe' | Write-Verbose
            (New-Object System.Net.WebClient).DownloadFile($nugetDownloadUrl, $nugetDestPath)

            # double check that is was written to disk
            if(!(Test-Path $nugetDestPath)){
                throw 'unable to download nuget'
            }
        }

        # return the path of the file
        $nugetDestPath
    }
}

function Enable-GetNuGet{
    [cmdletbinding()]
    param($toolsDir = "$env:LOCALAPPDATA\LigerShark\tools\getnuget\",
        $getNuGetDownloadUrl = 'https://raw.githubusercontent.com/sayedihashimi/publish-module/master/getnuget.psm1')
    process{
        if(!(get-module 'getnuget')){
            if(!(Test-Path $toolsDir)){ New-Item -Path $toolsDir -ItemType Directory -WhatIf:$false }

            $expectedPath = (Join-Path ($toolsDir) 'getnuget.psm1')
            if(!(Test-Path $expectedPath)){
                'Downloading [{0}] to [{1}]' -f $getNuGetDownloadUrl,$expectedPath | Write-Verbose
                (New-Object System.Net.WebClient).DownloadFile($getNuGetDownloadUrl, $expectedPath)
                if(!$expectedPath){throw ('Unable to download getnuget.psm1')}
            }

            'importing module [{0}]' -f $expectedPath | Write-Verbose
            Import-Module $expectedPath -DisableNameChecking -Force -Scope Global
        }
    }
}

<#
.SYNOPSIS 
This will inspect the publsish nuspec file and return the value for the Version element.
#>
function GetExistingVersion{
    [cmdletbinding()]
    param(
        [ValidateScript({test-path $_ -PathType Leaf})]
        $nuspecFile = (Join-Path $scriptDir 'psbuild.nuspec')
    )
    process{
        ([xml](Get-Content $nuspecFile)).package.metadata.version
    }
}

function UpdateVersion{
    [cmdletbinding()]
    param(
        [Parameter(Position=0,Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$newversion,

        [Parameter(Position=1)]
        [ValidateNotNullOrEmpty()]
        [string]$oldversion = (GetExistingVersion),

        [Parameter(Position=2)]
        [string]$filereplacerVersion = '0.2.0-beta'
    )
    process{
        'Updating version from [{0}] to [{1}]' -f $oldversion,$newversion | Write-Verbose
        Enable-GetNuGet
        'trying to load file replacer' | Write-Verbose
        Enable-NuGetModule -name 'file-replacer' -version $filereplacerVersion

        $folder = $scriptDir
        $include = '*.nuspec;*.ps*1'
        # In case the script is in the same folder as the files you are replacing add it to the exclude list
        $exclude = "$($MyInvocation.MyCommand.Name);"
        $replacements = @{
            "$oldversion"="$newversion"
        }
        Replace-TextInFolder -folder $folder -include $include -exclude $exclude -replacements $replacements | Write-Verbose
        'Replacement complete' | Write-Verbose
    }
}

function PublishNuGetPackage{
    [cmdletbinding()]
    param(
        [Parameter(Mandatory=$true,ValueFromPipeline=$true)]
        [string]$nugetPackages,

        [Parameter(Mandatory=$true)]
        $nugetApiKey
    )
    process{
        foreach($nugetPackage in $nugetPackages){
            $pkgPath = (get-item $nugetPackage).FullName
            $cmdArgs = @('push',$pkgPath,$nugetApiKey,'-NonInteractive')

            'Publishing nuget package with the following args: [nuget.exe {0}]' -f ($cmdArgs -join ' ') | Write-Verbose
            &(Get-Nuget) $cmdArgs
        }
    }
}


function Clean-OutputFolder{
    [cmdletbinding()]
    param()
    process{
        $outputFolder = Get-OutputRoot

        if(Test-Path $outputFolder){
            'Deleting output folder [{0}]' -f $outputFolder | Write-Host
            Remove-Item $outputFolder -Recurse -Force
        }

    }
}

function LoadPester{
    [cmdletbinding()]
    param(
        $pesterDir = (resolve-path (Join-Path $scriptDir 'contrib\pester\'))
    )
    process{
        if(!(Get-Module pester)){
            if($env:PesterDir -and (test-path $env:PesterDir)){
                $pesterDir = $env:PesterDir
            }

            if(!(Test-Path $pesterDir)){
                throw ('Pester dir not found at [{0}]' -f $pesterDir)
            }
            $modFile = (Join-Path $pesterDir 'Pester.psm1')
            'Loading pester from [{0}]' -f $modFile | Write-Verbose
            Import-Module (Join-Path $pesterDir 'Pester.psm1')
        }
    }
}

function Get-OutputRoot{
    [cmdletbinding()]
    param()
    process{
        Join-Path $scriptDir "OutputRoot"
    }
}

function Run-Tests{
    [cmdletbinding()]
    param(
        $testDirectory = (join-path $scriptDir tests)
    )
    begin{ 
        LoadPester
        $previousToolsDir = $env:PSBuildToolsDir
        $env:PSBuildToolsDir = (Join-Path (Get-OutputRoot) 'PSBuild\')
    }
    process{
        # go to the tests directory and run pester
        push-location
        set-location $testDirectory
        if($env:ExitOnPesterFail){
            invoke-pester -EnableExit
        }
        else{
            invoke-pester
        }

        $pesterArgs = @{}
        if($env:ExitOnPesterFail -eq $true){
            $pesterArgs.Add('-EnableExit',$true)
        }
        if($env:PesterEnableCodeCoverage -eq $true){
            $pesterArgs.Add('-CodeCoverage','..\src\psbuild.psm1')
        }

        Invoke-Pester @pesterArgs


        pop-location
    }
    end{
        $env:PSBuildToolsDir = $previousToolsDir
    }
}

function Build{
    [cmdletbinding()]
    param()
    process{
        if($publishToNuget){ $CleanOutputFolder = $true }

        if($CleanOutputFolder){
            Clean-OutputFolder
        }

        $projFilePath = get-item (Join-Path $scriptDir 'psbuild.proj')

        $msbuildArgs = @()
        $msbuildArgs += $projFilePath.FullName
        $msbuildArgs += '/p:Configuration=Release'
        $msbuildArgs += '/p:VisualStudioVersion=12.0'
        $msbuildArgs += '/flp1:v=d;logfile=msbuild.d.log'
        $msbuildArgs += '/flp2:v=diag;logfile=msbuild.diag.log'
        $msbuildArgs += '/m'

        & ((Get-MSBuildExe).FullName) $msbuildArgs

        Run-Tests

        # publish to nuget if selected
        if($publishToNuget){
            (Get-ChildItem -Path (Get-OutputRoot) 'psbuild*.nupkg').FullName | PublishNuGetPackage -nugetApiKey $nugetApiKey
        }
    }
}

if(!$build -and !$updateversion -and !$getversion){
    $build = $true
}


try{
    if($build){ Build }
    elseif($updateversion){ UpdateVersion -newversion $newversion }
    elseif($getversion){ GetExistingVersion | Write-Output }
    else{
        $cmds = @('-build','-updateversion')
        'Command not found or empty, please pass in one of the following [{0}]' -f ($cmds -join ' ') | Write-Error
    }
}
catch{
    "Build failed with an exception:`n{0}" -f ($_.Exception.Message) |  Write-Error
    exit 1
}
