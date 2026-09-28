using Mono.Cecil;
using Mono.Cecil.Cil;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

// IL patcher for the named-pipe paths that .NET hardcodes to "/tmp" on Unix.
//
// OpenHarmony denies AF_UNIX bind() under /tmp (EACCES), so every component that
// creates a Unix domain socket there fails: MSBuild task hosts / server / worker
// nodes (MSB4216) and the Roslyn compiler server (csc/vbc fall back to an
// in-process compile after a ~20 s connect timeout). Both use the same pattern:
//   Path.Combine("/tmp", pipeName)
// This tool rewrites that one `ldstr "/tmp"` into
//   call string System.IO.Path::GetTempPath()
// (TMPDIR-aware) inside the known pipe-name builders, in place.
//
// Targets (keep in sync with patch-msbuild-pipe.py and its --scan output):
//   MSBuild  Microsoft.Build.Shared.NamedPipeUtil::GetPlatformSpecificPipeName(string)
//            Microsoft.Build.BackEnd.NamedPipeUtil::GetPlatformSpecificPipeName(string)  (older MSBuild)
//   Roslyn   Microsoft.CodeAnalysis.NamedPipeUtil::GetPipeNameOrPath(string)
//            shipped in csc.dll, vbc.dll, VBCSCompiler.dll and in
//            Microsoft.Build.Tasks.CodeAnalysis.dll (the Csc/Vbc MSBuild task;
//            it carries the same client-side BuildServerConnection, so every
//            shipped copy must agree on the TMPDIR-derived path).
//
// Exit codes:
//   0 patched (>=1 instruction rewritten)
//   1 usage / unexpected failure
//   2 no known target type in the assembly (skip: not a pipe-bearing file)
//   3 target type found but the target method is missing (skip: version drift)
//   4 target method present but it has no "/tmp" literal (already patched/no-op)
class Program
{
    const int RcPatched = 0;
    const int RcUsage = 1;
    const int RcNoTargetType = 2;
    const int RcNoTargetMethod = 3;
    const int RcNothingToDo = 4;

    sealed class PipeTarget
    {
        public readonly string Kind;
        public readonly string[] TypeNames;
        public readonly string MethodName;
        public PipeTarget(string kind, string[] typeNames, string methodName)
        {
            Kind = kind;
            TypeNames = typeNames;
            MethodName = methodName;
        }
    }

    static readonly PipeTarget[] s_targets =
    {
        new PipeTarget("MSBuild", new[]
        {
            "Microsoft.Build.Shared.NamedPipeUtil",
            "Microsoft.Build.BackEnd.NamedPipeUtil",
        }, "GetPlatformSpecificPipeName"),
        new PipeTarget("Roslyn", new[]
        {
            "Microsoft.CodeAnalysis.NamedPipeUtil",
        }, "GetPipeNameOrPath"),
    };

    static int Main(string[] args)
    {
        if (args.Length >= 2 && args[0] == "--scan")
            return Scan(args.Skip(1).ToArray());
        if (args.Length != 2)
        {
            Console.WriteLine("usage: msbuild-pipe-patch <in.dll> <out.dll>");
            Console.WriteLine("       msbuild-pipe-patch --scan <dll>...   # list ldstr \"/tmp\" methods");
            return RcUsage;
        }
        return Patch(args[0], args[1]);
    }

    static AssemblyDefinition ReadAssembly(string path)
    {
        var resolver = new DefaultAssemblyResolver();
        resolver.AddSearchDirectory(Path.GetDirectoryName(Path.GetFullPath(path)));
        return AssemblyDefinition.ReadAssembly(path, new ReaderParameters
        {
            AssemblyResolver = resolver,
            ReadSymbols = false
        });
    }

    static int Patch(string input, string output)
    {
        var asm = ReadAssembly(input);
        int patched = 0, typesFound = 0, methodsFound = 0;
        var seen = new HashSet<string>();

        foreach (var type in AllTypes(asm.MainModule.Types))
        {
            foreach (var target in s_targets)
            {
                if (!target.TypeNames.Contains(type.FullName)) continue;
                if (!seen.Add(type.FullName)) continue;
                typesFound++;

                var method = type.Methods.FirstOrDefault(m =>
                    m.Name == target.MethodName &&
                    m.Parameters.Count == 1 &&
                    m.Parameters[0].ParameterType.MetadataType == MetadataType.String &&
                    m.HasBody);
                if (method == null)
                {
                    Console.WriteLine($"SKIP {target.Kind}: {type.FullName}::{target.MethodName}(string) not found");
                    continue;
                }
                methodsFound++;

                int n = ReplaceTempLiteral(method);
                patched += n;
                if (n > 0)
                    Console.WriteLine($"PATCHED {target.Kind}: {method.FullName} ({n} ldstr \"/tmp\")");
                else
                    Console.WriteLine($"NOOP {target.Kind}: {method.FullName} has no \"/tmp\" literal (already patched?)");
            }
        }

        if (typesFound == 0)
        {
            Console.WriteLine("SKIP: no pipe target type found; candidates:");
            Console.WriteLine("asm: " + asm.FullName + " modules=" + asm.Modules.Count + " typedefs(top)=" + asm.MainModule.Types.Count);
            foreach (var t in asm.MainModule.Types)
                foreach (var x in AllTypes(t))
                    if (x.Name.Contains("Pipe", StringComparison.OrdinalIgnoreCase) || x.Name.StartsWith("Named"))
                        Console.WriteLine("  td: " + x.FullName);
            foreach (var tr in asm.MainModule.GetTypeReferences())
                if (tr.Name.Contains("Pipe", StringComparison.OrdinalIgnoreCase))
                    Console.WriteLine("  typeref: " + tr.FullName + " scope=" + tr.Scope);
            return RcNoTargetType;
        }
        if (methodsFound == 0)
            return RcNoTargetMethod;
        if (patched == 0)
            return RcNothingToDo;

        asm.Write(output);
        Console.WriteLine($"patched instructions: {patched}; written: {output}");
        return RcPatched;
    }

    // `ldstr "/tmp"` (5 bytes: opcode + token) -> `call Path.GetTempPath()`
    // (also 5 bytes), so no branch fixups are needed. Path.GetTempPath() returns
    // TMPDIR (with trailing separator) on Unix, e.g.
    // "/data/storage/el2/base/tmp/".
    static int ReplaceTempLiteral(MethodDefinition method)
    {
        var getTempPath = GetTempPathReference(method);
        int n = 0;
        foreach (var instr in method.Body.Instructions)
        {
            if (instr.OpCode == OpCodes.Ldstr && (string)instr.Operand == "/tmp")
            {
                instr.OpCode = OpCodes.Call;
                instr.Operand = getTempPath;
                n++;
            }
        }
        return n;
    }

    static MethodReference GetTempPathReference(MethodDefinition method)
    {
        // Prefer the assembly's own System.IO.Path reference so the scope of the
        // emitted call matches the target (System.Runtime / System.Private.CoreLib).
        var pathTypeRef = method.Module.GetTypeReferences().FirstOrDefault(t => t.FullName == "System.IO.Path");
        if (pathTypeRef != null)
            return new MethodReference("GetTempPath", method.Module.TypeSystem.String, pathTypeRef) { HasThis = false };
        return method.Module.ImportReference(typeof(Path).GetMethod(nameof(Path.GetTempPath), Type.EmptyTypes));
    }

    // Diagnostic mode: print every method that contains a `ldstr` operand with
    // the given substring (default "/tmp") plus nearby IL.
    static int Scan(string[] files)
    {
        foreach (var file in files)
        {
            var asm = ReadAssembly(file);
            Console.WriteLine("== " + file);
            foreach (var type in AllTypes(asm.MainModule.Types))
            {
                foreach (var m in type.Methods)
                {
                    if (!m.HasBody) continue;
                    var ins = m.Body.Instructions;
                    var hits = ins.Where(x => x.OpCode == OpCodes.Ldstr &&
                                              x.Operand is string s &&
                                              s.Contains("/tmp", StringComparison.Ordinal)).ToList();
                    foreach (var hit in hits)
                    {
                        Console.WriteLine($"  {type.FullName}::{m.Name}: ldstr \"{hit.Operand}\"");
                        if (m.Name == "GetPlatformSpecificPipeName" || m.Name == "GetPipeNameOrPath")
                            foreach (var x in ins)
                                Console.WriteLine("      " + x);
                    }
                }
            }
        }
        return RcPatched;
    }

    static IEnumerable<TypeDefinition> AllTypes(IEnumerable<TypeDefinition> tops)
    {
        foreach (var t in tops)
            foreach (var x in AllTypes(t))
                yield return x;
    }

    static IEnumerable<TypeDefinition> AllTypes(TypeDefinition t)
    {
        yield return t;
        foreach (var n in t.NestedTypes)
            foreach (var x in AllTypes(n))
                yield return x;
    }
}
