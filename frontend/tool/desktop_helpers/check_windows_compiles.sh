#!/usr/bin/env bash
# Dev check that the Windows desktop window helper (assets/helpers/everyai_win.cs) compiles as Windows will compile
# it (.NET Framework 4.8 references, C# 5), from any OS with the .NET SDK. It is not run here.
set -euo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
src="$PWD/../../assets/helpers/everyai_win.cs"
cat > "$work/check.csproj" <<PROJ
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net48</TargetFramework>
    <LangVersion>5</LangVersion>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="$src" />
    <PackageReference Include="Microsoft.NETFramework.ReferenceAssemblies" Version="1.0.3" PrivateAssets="all" />
    <Reference Include="System.Drawing" />
    <Reference Include="UIAutomationClient" />
    <Reference Include="UIAutomationTypes" />
    <Reference Include="WindowsBase" />
  </ItemGroup>
</Project>
PROJ
dotnet build "$work/check.csproj" -nologo -v q
