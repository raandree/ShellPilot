BeforeAll {
    $script:moduleName = 'ShellPilot'

    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
    Import-Module -Name $script:moduleName -Force -ErrorAction Stop
}

AfterAll {
    Get-Module -Name $script:moduleName -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'New-ShpHttpErrorDetail' {
    It 'Exposes mandatory StatusCode and RequestUri parameters' {
        InModuleScope $script:moduleName {
            $cmd = Get-Command -Name New-ShpHttpErrorDetail
            $cmd.Parameters['StatusCode'].Attributes.Mandatory | Should -Contain $true
            $cmd.Parameters['RequestUri'].Attributes.Mandatory | Should -Contain $true
        }
    }

    It 'Pulls the code, param and message out of an error envelope' {
        InModuleScope $script:moduleName {
            $detail = New-ShpHttpErrorDetail -StatusCode 400 -RequestUri 'https://api.example/responses' `
                -Body '{"error":{"message":"store is not supported","code":"unsupported_value","param":"store","type":"invalid_request_error"}}'

            $detail.StatusCode | Should -Be 400
            $detail.ErrorCode  | Should -Be 'unsupported_value'
            $detail.Param      | Should -Be 'store'
            $detail.Message    | Should -BeExactly 'store is not supported'
            $detail.RequestUri | Should -Be 'https://api.example/responses'
        }
    }

    It 'Leaves the parsed members null for a body that is not an error envelope' {
        InModuleScope $script:moduleName {
            $detail = New-ShpHttpErrorDetail -StatusCode 502 -RequestUri 'https://api.example/chat/completions' `
                -Body '<html><body>502 Bad Gateway</body></html>'

            $detail.ErrorCode | Should -BeNullOrEmpty
            $detail.Param     | Should -BeNullOrEmpty
            $detail.Message   | Should -BeNullOrEmpty
            $detail.Body      | Should -BeExactly '<html><body>502 Bad Gateway</body></html>'
        }
    }

    It 'Keeps the whole body however large' {
        InModuleScope $script:moduleName {
            $detail = New-ShpHttpErrorDetail -StatusCode 500 -RequestUri 'https://api.example/x' -Body ('x' * 20000)
            $detail.Body.Length | Should -Be 20000
        }
    }

    It 'Renders short by default so the body cannot be interpolated into a prompt' {
        InModuleScope $script:moduleName {
            $detail = New-ShpHttpErrorDetail -StatusCode 400 -RequestUri 'https://api.example/x' `
                -Body '{"error":{"message":"store is not supported","code":"unsupported_value","param":"store"}}'

            ('{0}' -f $detail) | Should -BeExactly 'HTTP 400 unsupported_value (param store) - store is not supported'
        }
    }

    It 'Renders the status alone when the body says nothing structured' {
        InModuleScope $script:moduleName {
            $detail = New-ShpHttpErrorDetail -StatusCode 500 -RequestUri 'https://api.example/x' -Body ('x' * 20000)
            ('{0}' -f $detail) | Should -BeExactly 'HTTP 500'
        }
    }

    It 'Accepts an empty body' {
        InModuleScope $script:moduleName {
            $detail = New-ShpHttpErrorDetail -StatusCode 502 -RequestUri 'https://api.example/x' -Body ''
            $detail.StatusCode | Should -Be 502
            $detail.Body       | Should -BeExactly ''
        }
    }
}
