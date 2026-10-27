import Foundation

// Which listening ports are dev servers you're running — and what they are.
//
// A busy machine lists ~40 ports, and most are noise for "what am I working
// on": browser debug ports, MCP servers, agent harness sockets, inspector
// ports, a dev tool's internal plumbing, app helpers. The same layered
// approach the port tools in this space use (devports, berth, portctl,
// LocalhostBar): rule out the known noise first — precision matters more than
// recall, a wrong "dev server" is worse than a missing one — then name what's
// left from its command line, then its project from its working directory.
//
// Everything here is local and passive: command lines Pier already reads,
// libproc for the directory, and a bounded read of the project's own
// manifest. No HTTP probing — a GET to an arbitrary listener can have side
// effects, and it would break the privacy contract.

/// A port recognised as a dev server.
struct DevServer: Equatable, Sendable {
  /// "Angular", "Vite", "Wrangler", "Node"…
  let framework: String
  /// Display name of the project, disambiguated when two share a name.
  var project: String?
  /// Project root, for the tooltip and for telling same-named projects apart.
  var projectPath: String?

  var label: String { project.map { "\(framework) · \($0)" } ?? framework }
}

/// What a project manifest says about itself.
struct ProjectInfo: Equatable, Sendable {
  let root: String
  let name: String
}

enum DevServers {
  // MARK: - Rule 1: never a dev server

  /// Long-running local services that listen but aren't something you're
  /// developing. Matched on the executable's basename.
  static let infrastructure: Set<String> = [
    "adb", "postgres", "mysqld", "mariadbd", "redis-server", "mongod", "memcached",
    "ollama", "rapportd", "sharingd", "controlcenter", "syncthing", "tailscaled",
    "cloudflared", "ngrok", "ssh", "sshd", "colima", "limactl", "qemu-system-aarch64",
  ]

  /// Why a process can't be a dev server, or nil if it might be.
  static func exclusion(command: String, processName: String) -> String? {
    let lower = command.lowercased()
    let argv0 = String(Attributor.firstToken(command))
    let binary = URL(fileURLWithPath: argv0).lastPathComponent.lowercased()
    if Attributor.isSystemBinary(command) { return "system binary" }
    // Nothing you're developing runs from inside an app bundle: this is
    // Chrome for Testing, Google Drive, Blender, editor helpers, harness apps.
    if argv0.contains(".app/Contents/") { return "app bundle" }
    if lower.contains("--remote-debugging-port") { return "browser debug port" }
    if ActivityParser.isMCPCommand(lower) { return "MCP server" }
    if infrastructure.contains(binary) { return "local service" }
    // The agent harness or terminal itself (claude's IDE socket, a Ghostty
    // helper) — the process *is* the harness, not something it launched.
    if Attributor.harnessLabel(for: processName) != nil
      || Attributor.harnessLabel(for: binary) != nil
    {
      return "agent harness"
    }
    return nil
  }

  // MARK: - Rule 2: a dev tool's own plumbing

  /// Ports a dev process opens that aren't the server you browse: debuggers
  /// and a dev tool's internal sockets.
  static func isInternalPort(_ port: Int, command: String) -> Bool {
    let args = command.split(separator: " ").map(String.init)
    for arg in args {
      // node --inspect[=host:]port / --inspect-brk / --inspect-port
      for flag in ["--inspect=", "--inspect-brk=", "--inspect-port="] where arg.hasPrefix(flag) {
        if portSuffix(arg) == port { return true }
      }
      if arg == "--inspect" || arg == "--inspect-brk", port == 9229 { return true }
      if arg.hasPrefix("--inspector-addr="), portSuffix(arg) == port { return true }
    }
    return false
  }

  /// workerd (wrangler's runtime) listens on several ports; the one you open
  /// in a browser is the `entry` socket. A random `entry=…:0` is wrangler's
  /// internal user worker, behind its proxy.
  static func workerdEntryPort(_ command: String) -> Int? {
    for arg in command.split(separator: " ") where arg.hasPrefix("--socket-addr=entry=") {
      if let port = portSuffix(String(arg)), port > 0 { return port }
    }
    return nil
  }

  private static func portSuffix(_ arg: String) -> Int? {
    arg.split(separator: ":").last.flatMap { Int($0.split(separator: "=").last ?? $0) }
  }

  // MARK: - Rule 3: what is it

  struct Signature {
    let framework: String
    /// Any of these, as a substring of the lowercased command line.
    let needles: [String]
  }

  /// Framework / tool signatures, most specific first. Matched against the
  /// command *string*, not the process name: Angular renames its process to
  /// `ng serve (app)` while `ps` still reports `node`.
  static let signatures: [Signature] = [
    Signature(framework: "Angular", needles: ["ng serve", "@angular/cli", "@angular-devkit"]),
    Signature(
      framework: "Next.js", needles: ["next dev", "next start", "next-server", "/next/dist/"]),
    Signature(framework: "Nuxt", needles: ["nuxi dev", "nuxt dev", "/nuxt/bin", "/nuxi/bin"]),
    Signature(framework: "Astro", needles: ["astro dev", "/astro/astro.js"]),
    Signature(framework: "Remix", needles: ["remix dev", "remix-serve", "remix vite:dev"]),
    Signature(framework: "SvelteKit", needles: ["svelte-kit dev"]),
    Signature(
      framework: "Storybook", needles: ["storybook dev", "start-storybook", "/storybook/"]),
    Signature(framework: "Gatsby", needles: ["gatsby develop"]),
    Signature(framework: "Expo", needles: ["expo start", "/expo/bin"]),
    Signature(framework: "Metro", needles: ["react-native start", "/metro/"]),
    Signature(framework: "Create React App", needles: ["react-scripts start"]),
    Signature(framework: "webpack", needles: ["webpack serve", "webpack-dev-server"]),
    Signature(
      framework: "Vite", needles: ["/.bin/vite", "/vite/bin/vite", "vite dev", " vite ", "vite.js"]),
    Signature(framework: "Parcel", needles: ["/.bin/parcel", "parcel serve"]),
    Signature(framework: "Eleventy", needles: ["@11ty", "eleventy --serve"]),
    Signature(
      framework: "Firebase",
      needles: ["firebase emulators", "firebase-tools", "cloud-firestore-emulator"]),
    Signature(framework: "Wrangler", needles: ["wrangler dev"]),
    Signature(framework: "Rails", needles: ["rails server", "rails s ", "bin/rails s", "puma"]),
    Signature(framework: "Django", needles: ["manage.py runserver"]),
    Signature(framework: "Flask", needles: ["flask run"]),
    Signature(framework: "FastAPI", needles: ["fastapi dev", "fastapi run"]),
    Signature(framework: "Uvicorn", needles: ["uvicorn"]),
    Signature(framework: "Gunicorn", needles: ["gunicorn"]),
    Signature(framework: "Laravel", needles: ["artisan serve"]),
    Signature(framework: "PHP", needles: ["php -s "]),
    Signature(framework: "Phoenix", needles: ["phx.server"]),
    Signature(framework: "Hugo", needles: ["hugo server"]),
    Signature(framework: "Jekyll", needles: ["jekyll serve"]),
    Signature(framework: "Python http.server", needles: ["http.server"]),
    Signature(framework: "Static server", needles: ["http-server", "live-server", "/.bin/serve "]),
    Signature(framework: ".NET", needles: ["dotnet watch", "dotnet run"]),
    Signature(framework: "Spring Boot", needles: ["spring-boot", "bootrun"]),
    Signature(framework: "Go", needles: ["go run ", "/go-build"]),
    Signature(framework: "nodemon", needles: ["nodemon"]),
  ]

  /// Runtimes that run your own server scripts. A script-running runtime in a
  /// project directory is a dev server even when no framework names itself —
  /// a hand-written `node server.mjs` is exactly what you're developing.
  static let runtimes: [String: String] = [
    "node": "Node", "bun": "Bun", "deno": "Deno", "ruby": "Ruby", "php": "PHP",
    "python": "Python", "python3": "Python",
  ]

  static func signature(in command: String) -> String? {
    let lower = " " + command.lowercased() + " "
    return signatures.first { sig in sig.needles.contains { lower.contains($0) } }?.framework
  }

  static func runtime(of command: String) -> String? {
    let binary = URL(fileURLWithPath: String(Attributor.firstToken(command))).lastPathComponent
      .lowercased()
    if let label = runtimes[binary] { return label }
    // python3.11, python3.12…
    if binary.hasPrefix("python3") { return "Python" }
    return nil
  }

  // MARK: - Classification

  /// One port → a dev server, or nil.
  ///
  /// `chain` is the listening process first, then its ancestors; parents are
  /// consulted for a framework name (`npm run dev` → `vite`) but never let a
  /// port through that its own process ruled out.
  static func classify(
    port: Int, chain: [ProcessTable.Proc], commands: [Int32: String],
    directory: (Int32) -> String?, project: (String) -> ProjectInfo?,
    home: String = NSHomeDirectory()
  ) -> DevServer? {
    guard let process = chain.first else { return nil }
    let command = commands[process.pid] ?? process.name
    if exclusion(command: command, processName: process.name) != nil { return nil }
    if isInternalPort(port, command: command) { return nil }

    let binary = URL(fileURLWithPath: String(Attributor.firstToken(command))).lastPathComponent
    var framework: String?
    if binary == "workerd" {
      guard workerdEntryPort(command) == port else { return nil }
      framework = "Wrangler"
    } else if command.contains("/wrangler/") || command.contains("wrangler-dist") {
      // Wrangler's own node process is a proxy and an inspector; the server
      // you browse is workerd's entry socket.
      return nil
    } else {
      framework = signature(in: command)
      // A launcher above it may name the tool (`npm run dev` → its child is
      // a bare `node …/cli.js`). Stop at the first shell, terminal or harness.
      if framework == nil {
        for parent in chain.dropFirst().prefix(4) {
          let parentCommand = commands[parent.pid] ?? parent.name
          if Attributor.harnessLabel(for: parent.name) != nil
            || ["zsh", "bash", "fish", "sh", "login"].contains(parent.name)
          {
            break
          }
          if let found = signature(in: parentCommand) {
            framework = found
            break
          }
        }
      }
    }

    let cwd = directory(process.pid)
    let info = cwd.flatMap { dir -> ProjectInfo? in
      guard dir != home, dir != "/", dir.hasPrefix(home + "/") else { return nil }
      return project(dir)
    }

    if framework == nil {
      // The generic case — a runtime running a script — needs a project
      // directory to count; a node process sitting in ~ is some tool's helper.
      guard let runtime = runtime(of: command), Attributor.firstToken(command) != command,
        info != nil
      else { return nil }
      framework = runtime
    }
    return DevServer(framework: framework!, project: info?.name, projectPath: info?.root)
  }

  /// Two projects with the same name ("api" in two repos, or one repo checked
  /// out twice) read identically. Each gets the shortest run of its parent
  /// folders that tells it apart: "idle-server (lanes/a)" vs "(scratch/a)" —
  /// one folder ("(a)" and "(a)") wasn't always enough.
  static func disambiguate(_ servers: [DevServer?]) -> [DevServer?] {
    var paths: [String: Set<String>] = [:]
    for server in servers.compactMap({ $0 }) {
      guard let name = server.project, let path = server.projectPath else { continue }
      paths[name, default: []].insert(path)
    }
    var suffix: [String: String] = [:]
    for (_, group) in paths where group.count > 1 {
      let parents = group.map { path in
        URL(fileURLWithPath: path).deletingLastPathComponent().pathComponents.filter { $0 != "/" }
      }
      let deepest = parents.map(\.count).max() ?? 1
      var depth = 1
      while depth < deepest,
        Set(parents.map { $0.suffix(depth).joined(separator: "/") }).count < group.count
      {
        depth += 1
      }
      for (path, parent) in zip(group, parents) {
        // A project directly under "/" has no parent folder to show.
        let tail = parent.suffix(depth).joined(separator: "/")
        suffix[path] = tail.isEmpty ? "/" : tail
      }
    }
    return servers.map { server in
      guard var server, let name = server.project, let path = server.projectPath,
        let tail = suffix[path]
      else { return server }
      server.project = "\(name) (\(tail))"
      return server
    }
  }

  // MARK: - Projects on disk

  static let markers = [
    "package.json", "deno.json", "pyproject.toml", "Gemfile", "go.mod", "Cargo.toml",
    "composer.json", "mix.exs", "pom.xml", "build.gradle", ".git",
  ]

  /// Walk up from `directory` to the first project marker, stopping before
  /// `home`. Name from `package.json`'s `name` when there is one, else the
  /// folder. With no marker at all, the directory itself names the project —
  /// a script run from a plain folder under ~ is still yours.
  nonisolated static func readProject(
    _ directory: String, home: String = NSHomeDirectory(),
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    readFile: (String) -> Data? = { path in
      guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
      defer { try? handle.close() }
      return try? handle.read(upToCount: 64 * 1024)
    }
  ) -> ProjectInfo? {
    var dir = URL(fileURLWithPath: directory).standardizedFileURL
    for _ in 0..<8 {
      let path = dir.path
      guard path.hasPrefix(home + "/") else { break }
      if markers.contains(where: { fileExists(path + "/" + $0) }) {
        return ProjectInfo(
          root: path, name: manifestName(in: path, readFile: readFile) ?? dir.lastPathComponent)
      }
      dir.deleteLastPathComponent()
    }
    let fallback = URL(fileURLWithPath: directory)
    return ProjectInfo(root: fallback.path, name: fallback.lastPathComponent)
  }

  static func manifestName(in root: String, readFile: (String) -> Data?) -> String? {
    guard let data = readFile(root + "/package.json"),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let name = json["name"] as? String, !name.isEmpty
    else { return nil }
    return name
  }
}
