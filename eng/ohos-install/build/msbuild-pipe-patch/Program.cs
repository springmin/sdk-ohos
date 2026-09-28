using Mono.Cecil;
using Mono.Cecil.Cil;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

class Program
{
    static IEnumerable<TypeDefinition> AllTypes(TypeDefinition t)
    {
        yield return t;
        foreach (var n in t.NestedTypes)
            foreach (var x in AllTypes(n))
                yield return x;
    }

    static int Main(string[] args)
    {
        if (args.Length < 2)
        {
            Console.WriteLine("usage: patcher <in.dll> <out.dll>");
            return 1;
        }
        string input = args[0];
        string output = args[1];

        var resolver = new DefaultAssemblyResolver();
        resolver.AddSearchDirectory(Path.GetDirectoryName(Path.GetFullPath(input)));
        var rp = new ReaderParameters { AssemblyResolver = resolver, ReadWrite = false, ReadSymbols = false };
        var asm = AssemblyDefinition.ReadAssembly(input, rp);

        TypeDefinition type = null;
        foreach (var t in asm.MainModule.Types)
        {
            type = AllTypes(t).FirstOrDefault(x =>
                x.FullName == "Microsoft.Build.Shared.NamedPipeUtil" ||
                x.FullName == "Microsoft.Build.BackEnd.NamedPipeUtil");
            if (type != null) break;
        }
        if (type == null)
        {
            Console.WriteLine("ERROR: NamedPipeUtil type not found; candidates:");
            Console.WriteLine("asm: " + asm.FullName + " modules=" + asm.Modules.Count + " typedefs(top)=" + asm.MainModule.Types.Count);
            int n = 0;
            foreach (var t in asm.MainModule.Types)
                foreach (var x in AllTypes(t))
                {
                    if (x.Name.Contains("Pipe", StringComparison.OrdinalIgnoreCase) || x.FullName.Contains("NamedPipe"))
                        Console.WriteLine("  td: " + x.FullName + "  (attrs=" + x.Attributes + ")");
                    if (x.Name.StartsWith("Named") || x.Name.StartsWith("MSBuild"))
                        Console.WriteLine("  near: " + x.FullName);
                    n++;
                }
            foreach (var tr in asm.MainModule.GetTypeReferences())
                if (tr.Name.Contains("Pipe", StringComparison.OrdinalIgnoreCase))
                    Console.WriteLine("  typeref: " + tr.FullName + " scope=" + tr.Scope);
            Console.WriteLine("total types: " + n);
            return 2;
        }

        Console.WriteLine("Type: " + type.FullName);
        foreach (var m in type.Methods)
            Console.WriteLine("  method: " + m.FullName);

        MethodDefinition method = type.Methods.FirstOrDefault(m =>
            m.Name == "GetPlatformSpecificPipeName" &&
            m.Parameters.Count == 1 &&
            m.Parameters[0].ParameterType.MetadataType == MetadataType.String);
        if (method == null)
        {
            Console.WriteLine("ERROR: GetPlatformSpecificPipeName(string) not found");
            return 3;
        }

        Console.WriteLine("Patching: " + method.FullName);
        int patched = 0;
        foreach (var instr in method.Body.Instructions)
        {
            Console.WriteLine("  IL: " + instr);
            if (instr.OpCode == OpCodes.Ldstr && (string)instr.Operand == "/tmp")
            {
                MethodReference getTempPath;
                var pathTypeRef = method.Module.GetTypeReferences().FirstOrDefault(t => t.FullName == "System.IO.Path");
                if (pathTypeRef != null)
                {
                    getTempPath = new MethodReference("GetTempPath", method.Module.TypeSystem.String, pathTypeRef)
                    {
                        HasThis = false
                    };
                }
                else
                {
                    getTempPath = method.Module.ImportReference(typeof(Path).GetMethod(nameof(Path.GetTempPath), Type.EmptyTypes));
                }
                instr.OpCode = OpCodes.Call;
                instr.Operand = getTempPath;
                patched++;
            }
        }

        Console.WriteLine($"patched instructions: {patched}");
        if (patched == 0)
            return 4;

        asm.Write(output);
        Console.WriteLine("written: " + output);
        return 0;
    }
}
