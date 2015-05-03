module test.programs;

import std.algorithm;
import std.array;
import std.datetime;
import std.exception;
import std.file;
import std.format;
import std.path;
import std.process;
import std.stdio;
import std.string;
import std.typetuple;

import ae.utils.meta;
import ae.utils.xmllite : encodeEntities;

import common;

const string[] dmdFlags = ["-O", "-inline", "-release"];

version (Posix)
{
	import core.sys.posix.sys.resource;
	import core.sys.posix.sys.wait;
	import core.stdc.errno;

	extern(C) pid_t wait4(pid_t pid, int *status, int options, rusage *rusage);
}

struct ProgramInfo
{
	string id, name, rawCode;
	int iterations = 10;

	@property string code()
	{
		return rawCode
			.replace("\n\t\t", "\n")
			.replace("\t", "    ")
			.strip()
		;
	}
}

const ProgramInfo[] programs = [
	ProgramInfo("empty", "Empty program", q{
		void main()
		{
		}
	}),

	ProgramInfo("hello", "\"Hello, world\"", q{
		import std.stdio;

		void main()
		{
			writeln("Hello, world!");
		}
	}),
];

struct ExecutionStats
{
	long realTime, userTime, kernelTime, maxRSS;
}

final class Program
{
	ProgramInfo info;

	this(ProgramInfo info) { this.info = info; }

	static struct State
	{
		Target source, compile, link, run;
	}
	State state;

	@property string srcDir() { return d.config.local.workDir.buildPath("temp-trend"); }
	@property string srcFile() { return srcDir.buildPath("test.d"); }
	@property string objFile() { return srcDir.buildPath("test" ~ (isVersion!`Windows` ? ".obj" : ".o")); }
	@property string exeFile() { return srcDir.buildPath("test" ~ (isVersion!`Windows` ? ".exe" : "")); }

	class Target
	{
		ExecutionStats bestStats;
		int runs;

		abstract @property Target[] dependencies();
		abstract @property string[] command();
		abstract @property string outputFile();

		void need(int runs = 1)
		{
			foreach (dependency; dependencies)
				dependency.need();
			if (runs > this.runs)
			{
				run(runs - this.runs);
				this.runs = runs;
			}
		}

		void run(int iterations)
		{
			auto oldPath = environment["PATH"];
			scope(exit) environment["PATH"] = oldPath;
			environment["PATH"] = buildPath(d.buildDir, "bin").absolutePath() ~ pathSeparator ~ oldPath;
			log("PATH=" ~ environment["PATH"]);

			if (runs == 0)
				foreach (ref n; bestStats.tupleof)
					n = typeof(n).max;

			foreach (iteration; 0..iterations)
			{
				if (outputFile && outputFile.exists)
					outputFile.remove();

				log("Running program: %s".format(command));
				auto pid = spawnProcess(command, stdin, stdout, stderr, null, std.process.Config.none, srcDir);

				ExecutionStats iterationStats;
				StopWatch sw;
				sw.start();

				version (Windows)
				{
					// Just measure something for some draft results
					auto status = wait(pid);
					enforce(status == 0, "%s failed with status %s".format(command, status));
				}
				else
				{
					rusage rusage;

					while (true)
					{
						int status;
						auto check = wait4(pid.osHandle, &status, 0, &rusage);
						if (check == -1)
						{
							errnoEnforce(errno == EINTR, "Unexpected wait3 interruption");
							continue;
						}

						enforce(!WIFSIGNALED(status), "Program failed with signal %s".format(status));
						if (!WIFEXITED(status))
							continue;

						enforce(WEXITSTATUS(status) == 0, "Program failed with status %s".format(status));
						break;
					}

					long nsecs(timeval tv) { return tv.tv_sec * 1_000_000_000L + tv.tv_usec * 1_000L; }

					iterationStats.userTime   = nsecs(rusage.ru_utime);
					iterationStats.kernelTime = nsecs(rusage.ru_stime);
					iterationStats.maxRSS     = rusage.ru_maxrss * 1024L;
				}

				sw.stop();
				iterationStats.realTime = sw.peek().hnsecs * 100L;

				if (outputFile)
					enforce(outputFile.exists, "Program did not create output file " ~ outputFile);

				foreach (i, n; bestStats.tupleof)
					bestStats.tupleof[i] = min(bestStats.tupleof[i], iterationStats.tupleof[i]);
			}
		}
	}

	class Source : Target
	{
		override @property Target[] dependencies() { return null; }
		override @property string[] command() { assert(false); }
		override @property string outputFile() { assert(false); }
		override void run(int runs)
		{
			assert(runs==1);
			if (srcDir.exists)
				srcDir.rmdirRecurse();
			srcDir.mkdir();
			std.file.write(srcFile, info.code);
		}
	}

	class Compile : Target
	{
		override @property Target[] dependencies() { return [state.source]; }
		override @property string[] command() { return ["dmd", "-c"] ~ dmdFlags ~ ["test.d"]; }
		override @property string outputFile() { return objFile; }
	}

	class Link : Target
	{
		override @property Target[] dependencies() { return [state.compile]; }
		override @property string[] command() { return ["dmd", objFile.baseName]; }
		override @property string outputFile() { return exeFile; }
	}

	class Run : Target
	{
		override @property Target[] dependencies() { return [state.link]; }
		override @property string[] command() { return [exeFile.absolutePath()]; }
		override @property string outputFile() { return null; }
	}

	void reset()
	{
		if (srcDir.exists)
			srcDir.rmdirRecurse();

		state = State.init;
		state.source = new Source;
		state.compile = new Compile;
		state.link = new Link;
		state.run = new Run;
	}
}

abstract class ProgramTest : Test
{
	Program program;

	this(Program program) { this.program = program; }

	abstract @property string testID();
	abstract @property string testName();
	abstract @property string testDescription();

	override @property string id() { return "program-%s-%s-%d".format(program.info.id, testID, program.info.iterations); }
	override @property string name() { return "%s - %s".format(program.info.name, testName); }
	override @property string description() { return "The <span class='test-description'>%s</span> for the following program:<pre>%s</pre>".format(testDescription, encodeEntities(program.info.code)); }

	override void reset() { program.reset(); }
}

final class ObjectSizeTest : ProgramTest
{
	mixin GenerateContructorProxies;

	override @property string testID() { return "objectsize"; }
	override @property string testName() { return "object file size"; }
	override @property string testDescription() { return "file size of the compiled intermediary object file"; }
	override @property Unit unit() { return Unit.bytes; }
	override @property bool exact() { return true; }

	override long sample()
	{
		program.state.compile.need();
		return program.objFile.getSize();
	}
}

final class BinarySizeTest : ProgramTest
{
	mixin GenerateContructorProxies;

	override @property string testID() { return "binarysize"; }
	override @property string testName() { return "binary file size"; }
	override @property string testDescription() { return "file size of the linked executable binary file"; }
	override @property Unit unit() { return Unit.bytes; }
	override @property bool exact() { return true; }

	override long sample()
	{
		program.state.link.need();
		return program.exeFile.getSize();
	}
}

class ProgramPhaseTest : ProgramTest
{
	mixin GenerateContructorProxies;

	abstract @property string statID();
	abstract @property string statName();
	abstract @property string statDescription();

	abstract @property string stageID();
	abstract @property string stageName();
	abstract @property string stageDescription();
	abstract Program.Target getTarget();

	override @property string testID() { return "%s-%s".format(stageID, statID); }
	override @property string testName() { return "%s - %s".format(stageName, statName); }
	override @property string testDescription() { return "%s during %s (best of %d runs)".format(statDescription, stageDescription, program.info.iterations); }
}

class ProgramStatTest(string field, Unit _unit, bool _exact, string _name, string _description) : ProgramPhaseTest
{
	mixin GenerateContructorProxies;

	override @property string statID() { return field.toLower(); }
	override @property string statName() { return statName; }
	override @property string statDescription() { return _description; }
	override @property Unit unit() { return _unit; }
	override @property bool exact() { return _exact; }

	override long sample()
	{
		auto target = getTarget();
		target.need(program.info.iterations);
		auto stats = target.bestStats;
		return mixin("stats." ~ field);
	}
}

alias ProgramRealTimeTest    = ProgramStatTest!("realTime"  , Unit.nanoseconds, false, "real time"  , "total real (elapsed) time spent");
alias ProgramUserTimeTest    = ProgramStatTest!("userTime"  , Unit.nanoseconds, false, "user time"  , "total user time (CPU time spent in userspace) spent");
alias ProgramKernelTimeTest  = ProgramStatTest!("kernelTime", Unit.nanoseconds, false, "kernel time", "total kernel time (CPU time spent in the kernel) spent");
alias ProgramMemoryUsageTest = ProgramStatTest!("maxRSS"    , Unit.bytes      , true , "max RSS"    , "peak RSS (resident set size memory usage) used");

class ProgramCompilePhaseTest(StatTest) : StatTest
{
	mixin GenerateContructorProxies;
	override @property string stageID() { return "compile"; }
	override @property string stageName() { return "compilation"; }
	override @property string stageDescription() { return "compilation (<tt>dmd -c " ~ dmdFlags.join(" ") ~ "</tt> invocation)"; }
	override Program.Target getTarget() { return program.state.compile; }
}

class ProgramLinkPhaseTest(StatTest) : StatTest
{
	mixin GenerateContructorProxies;
	override @property string stageID() { return "link"; }
	override @property string stageName() { return "linking"; }
	override @property string stageDescription() { return "linking (<tt>dmd " ~ program.objFile.baseName ~ "</tt> invocation)"; }
	override Program.Target getTarget() { return program.state.link; }
}

class ProgramExecutionPhaseTest(StatTest) : StatTest
{
	mixin GenerateContructorProxies;
	override @property string stageID() { return "run"; }
	override @property string stageName() { return "execution"; }
	override @property string stageDescription() { return "test program execution"; }
	override Program.Target getTarget() { return program.state.run; }
}

static this()
{
	foreach (info; programs)
	{
		auto program = new Program(info);
		foreach (PhaseTest; TypeTuple!(ProgramCompilePhaseTest, ProgramLinkPhaseTest, ProgramExecutionPhaseTest))
			foreach (StatTest; TypeTuple!(ProgramRealTimeTest, ProgramUserTimeTest, ProgramKernelTimeTest, ProgramMemoryUsageTest))
				tests ~= new PhaseTest!StatTest(program);
		tests ~= new ObjectSizeTest(program);
		tests ~= new BinarySizeTest(program);
	}
}
