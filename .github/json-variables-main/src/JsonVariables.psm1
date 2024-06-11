$regexGithubExpression = '\${{\s*secrets.?(.*)\s*}}'
$regexJsonVarExpression = '#\{\s*?([^\{\}\|]*)\s*(?:\s*\|\s*)?(\w*)\}'

function Set-JsonVariables {

    [CmdletBinding()]
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $scope,
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $configFile,
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $secrets
    )
    $ErrorActionPreference = "Stop"

    $secretsList = ($secrets | ConvertFrom-Json -AsHashtable )
    $config = $configFile
    
    if(!(Test-Path $config)) {
        $config = Get-ChildItem -filter $configFile -recurse | Select-Object -First 1
    }

    if(!(Test-Path $config)) {
        Write-Error "Config file path does not exit: $config"
    }

    $json = Get-Content $config | out-string | ConvertFrom-Json

    # Add environment to variable
    $json.Variables += [PSCustomObject]@{
        Name='Context.Environment';
        Value=$scope;
    }

    # Find scoped environment if present
    $scopedEnvironment = $json.ScopeValues.Environments | Where-Object {$_.Name -eq $scope}

    # Find scoped variables based on target environment
    $targetVariables = $json.Variables | Where-Object {
        $_.Scope.Environment -contains $scopedEnvironment.Id `
        -OR $_.Scope.Environment -contains $scope `
        -OR [bool]($_.Scope.PSobject.Properties.name -match 'Environment') -eq $false 
        }

    $targetVariables = Invoke-ScoreVariables $targetVariables

    $targetVariables = Get-VariablesByPrecedens -variables $targetVariables

     if(!($null -eq $secretsList)) {

        # Find variables with secrets needing substitution    
        $needsSecretSubstituting = $targetVariables | Where-Object {
            $_.Value -match $regexGithubExpression
        }

        # Substitute secrets in variables
        $needsSecretSubstituting | ForEach-Object {
            $m = $_.Value | Select-String -pattern $regexGithubExpression
            $value = $m.Matches.Groups[1].Value
            
            $substition = $secretsList[$value]
            $_.Value = $_.Value -replace $regexGithubExpression, $substition
        }
     }

   

    $targetVariables = Invoke-SubstituteVariables $targetVariables


    $envValues = @()

    # Write alle variables to env
    $targetVariables | ForEach-Object {
        Write-Output "$($_.Name)=$($_.Value)" >> $Env:GITHUB_ENV
        $envValues += "$($_.Name)=$($_.Value)"
    }

    $Env:GITHUB_ENV | format-table

    return $envValues
}

 function Get-VariablesByPrecedens {
    [CmdletBinding()]
    param (
        [Parameter()]
        [PSCustomObject[]]
        $variables
    )

    $precedence = @()
    
    $groups = $variables | Group-Object -Property Name
    $groups | Foreach-Object {
            $precedence += $_.Group | Sort-Object -Property Score -Descending | Select-Object -First 1
    }

    return $precedence
}

function Invoke-ScoreVariables {
    [CmdletBinding()]
    param (
        [Parameter()]
        [PSCustomObject[]]
        $variables
    )
    $variables | ForEach-Object {
        $score = Get-Score $_
        $_ | Add-Member NoteProperty -Name Score -Value $score
    }
    return $variables
}

function Get-Score {
    [CmdletBinding()]
    param (
        [Parameter()]
        [PSCustomObject]
        $variable
    )

    $score = 0

    # Environment Scope
    if( [bool]($variable.PSobject.Properties.name -match "Scope") -eq $true `
        -AND [bool]($variable.Scope.PSobject.Properties.name -match "Environment") -eq $true `
        -AND $variable.Scope.Environment.Length -gt 0) {
            $score += 100
    }
    # No Scope
    else {
        $score += 10
    }

    return $score
}

function Invoke-SubstituteVariables {
    [CmdletBinding()]
    param (
        [Parameter()]
        [PSCustomObject[]]
        $variables
    )

     do{

        $substituted = 0

        # Find variables needing substitution    
        $needsSubstituting = $variables | Where-Object {
            $_.Value -match $regexJsonVarExpression
        }

        # Substitute variables
        $needsSubstituting | ForEach-Object {

            # Find variable name
            $match = $_.Value | Select-String -pattern $regexJsonVarExpression
            $name = $match.Matches.Groups[1].Value.Trim()
            
            # Lookup substitute value
            $substituteValue = $variables | Where-Object {$_.Name -eq $name}
            if(($substituteValue -match $regexJsonVarExpression)) {
                # do not substitute a value with a substitute expression. Continue
                return 
            }
            $value = $substituteValue.Value

            # Find optional filter
            $filterExpression = $null
            if($match.Matches.Groups.Count -gt 2) {
                $filterExpression = ($match.Matches.Groups[2].Value).ToLower()
            }

            # Execute optional filter expression
            if($filterExpression -eq 'tolower') {
                $value = $value.ToLower()
            } elseif ($filterExpression -eq 'toupper') {
                $value = $value.ToUpper()
            }

            # Perform substitution
            $_.Value = Invoke-ReplaceWithTargetRegex -substitution $_.Value -targetName $name -targetValue $value
            
            $substituted++
        }
        
    } while ($substituted -gt 0)

    return $variables
}

function Invoke-ReplaceWithTargetRegex {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $substitution,
        [Parameter()]
        [string]
        $targetName,
        [Parameter()]
        [string]
        $targetValue
    )

    $targetRegex = Get-RegexJsonVarExpressionForTargetValue -targetValue $targetName

    return $substitution -replace $targetRegex, $targetValue
}

function Get-RegexJsonVarExpressionForTargetValue {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $targetValue
    )

    return $regexJsonVarExpression.Replace('?([^\{\}\|]*)',$targetValue)
}

Export-ModuleMember -Function Set-JsonVariables, Invoke-ScoreVariables,  Get-Score, Get-VariablesByPrecedens, Invoke-SubstituteVariables, Get-RegexJsonVarExpressionForTargetValue, Invoke-ReplaceWithTargetRegex
Export-ModuleMember -Variable regexGithubExpression, regexJsonVarExpression