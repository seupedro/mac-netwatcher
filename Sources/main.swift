// Netwatch nativo - o netwatch na barra de menus do macOS, em Swift + AppKit.
//
// Um NSStatusItem mostra a latencia e, ao clicar, um menu com o painel
// desenhado a mao (sem WebView, sem HTML). Testa a conexao por TCP, entao
// funciona em redes que bloqueiam ping.
//
// Pensado para gastar o minimo de bateria: a fila da sonda registra as
// amostras sozinha e so acorda a thread principal quando o texto da barra
// precisa mudar ou quando o menu esta aberto. O painel so e desenhado com o
// menu aberto.

import AppKit

@MainActor
enum App {
    static var comum: Comum!
    static var sonda: Sonda!
    static var item: NSStatusItem!
    static var menu: NSMenu!
    static var painel: Painel!
    static var barraAplicada: UInt64 = 0
    static let fundoDeTeste = getenv("NETWATCH_PNG") != nil
    static var sinais: [DispatchSourceSignal] = []
    static var observadores: [NSObjectProtocol] = []

    /// Bolinha colorida e latencia no botao da barra de menus.
    static func aplicaBarra(_ b: Barra, _ f: Faixas) {
        if barraAplicada == b.versao { return }
        barraAplicada = b.versao
        guard let botao = item.button else { return }
        let cor: NSColor
        switch b.classe {
        case 0: cor = .tertiaryLabelColor
        case 1: cor = .systemRed
        default: cor = rgb(f.corDe(Int(b.classe) - 2, escuro: eEscura(botao.effectiveAppearance)))
        }
        let tam = NSFont.menuBarFont(ofSize: 0).pointSize
        let s = NSMutableAttributedString(string: "● ", attributes: [.font: NSFont.systemFont(ofSize: tam - 2), .foregroundColor: cor])
        s.append(NSAttributedString(string: b.txt, attributes: [.font: fonte(tam, .normal), .foregroundColor: NSColor.labelColor]))
        botao.attributedTitle = s
    }

    /// Roda na thread principal quando a fila da sonda pede.
    static func acordou(png: Bool, teste: Bool) {
        let aberto = comum.com { c -> Bool in
            aplicaBarra(c.barra, c.m.faixas)
            return c.menuAberto
        }
        if aberto { painel.needsDisplay = true }
        if png, let d = getenv("NETWATCH_PNG") {
            let destino = String(cString: d)
            // NETWATCH_PNG_AJUSTES=1: a imagem e da janela de configuracoes
            if let a = getenv("NETWATCH_PNG_AJUSTES") {
                Ajustes.salvaPng(destino, salvar: String(cString: a) == "salvar")
            } else {
                salvaPng(painel, destino)
            }
            encerrar()
        }
        if teste { testeDeMemoria() }
    }

    /// Para testes: NETWATCH_TESTE_MENU=s abre o menu por s segundos e
    /// NETWATCH_TESTE_AJUSTES=s abre a janela de configuracoes e clica no
    /// primeiro poco de cor (abre o painel de cores) por s segundos, para medir a memoria depois (o app continua).
    static func testeDeMemoria() {
        if let s = getenv("NETWATCH_TESTE_AJUSTES").flatMap({ Double(String(cString: $0)) }) {
            Ajustes.abrir()
            Ajustes.aberta?.clicaPrimeiroPoco()
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { Ajustes.aberta?.janela.close() }
        }
        if let s = getenv("NETWATCH_TESTE_MENU").flatMap({ Double(String(cString: $0)) }) {
            // o fechamento tem que rodar durante o laco do menu, que bloqueia aqui
            let t = Timer(timeInterval: s, repeats: false) { _ in MainActor.assumeIsolated { menu.cancelTracking() } }
            RunLoop.main.add(t, forMode: .common)
            item.button?.performClick(nil)
        }
    }

    /// Para testes: com NETWATCH_PNG=arquivo.png, desenha o painel fora da
    /// tela depois de 4 amostras, grava a imagem e sai.
    static func salvaPng(_ v: NSView, _ destino: String) {
        let b = v.bounds
        guard let rep = v.bitmapImageRepForCachingDisplay(in: b) else { return }
        v.cacheDisplay(in: b, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destino))
    }

    /// Linha com hora no ~/Library/Logs/Netwatch.log (stderr do LaunchAgent).
    nonisolated static func log(_ msg: String) {
        fputs("\(fmt(agora(), "%Y-%m-%d %H:%M:%S")) \(msg)\n", stderr)
    }

    static func encerrar() -> Never {
        comum?.com { $0.m.encerra() }
        exit(0)
    }

    /// Menu fechado: o painel nao vai ser desenhado tao cedo.
    static func menuFechou() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { devolveMemoria() }
    }

    /// Devolve ao sistema as paginas que o malloc guardou livres depois de
    /// desenhar o painel ou fechar a janela de configuracoes. Sem isso, o
    /// pico de uso fica contado no footprint para sempre (fragmentacao).
    static func devolveMemoria() {
        malloc_zone_pressure_relief(nil, 0)
    }

    static func itemMenu(_ titulo: String, _ acao: Selector, _ tecla: String) -> NSMenuItem {
        let it = NSMenuItem(title: titulo, action: acao, keyEquivalent: tecla)
        it.target = Acoes.shared
        return it
    }

    /// Menu principal invisivel (app de barra de menus nao mostra), so para os
    /// atalhos de edicao (⌘C, ⌘V, ⌘A...) e ⌘W funcionarem na janela de
    /// configuracoes. Os itens vao para quem estiver em foco (alvo nulo).
    static func menuPrincipal() -> NSMenu {
        func sub(_ titulo: String, _ itens: [(String, Selector, String)]) -> NSMenuItem {
            let m = NSMenu(title: titulo)
            for (t, a, k) in itens { m.addItem(NSMenuItem(title: t, action: a, keyEquivalent: k)) }
            let it = NSMenuItem()
            it.submenu = m
            return it
        }
        let principal = NSMenu()
        principal.addItem(sub("Netwatch", [("Fechar janela", #selector(NSWindow.performClose(_:)), "w")]))
        principal.addItem(sub("Editar", [
            ("Desfazer", Selector(("undo:")), "z"),
            ("Refazer", Selector(("redo:")), "Z"),
            ("Recortar", #selector(NSText.cut(_:)), "x"),
            ("Copiar", #selector(NSText.copy(_:)), "c"),
            ("Colar", #selector(NSText.paste(_:)), "v"),
            ("Selecionar tudo", #selector(NSText.selectAll(_:)), "a"),
        ]))
        return principal
    }

    /// Aberto pelo Finder/Launchpad com o LaunchAgent instalado: pede ao
    /// launchd para subir o servico e sai, em vez de rodar uma copia fora dele.
    static func redirecionaParaLaunchd(_ rotulo: String) {
        // com outra pasta de logs (testes) roda solto, sem mexer no servico
        let peloLaunchd = getenv("XPC_SERVICE_NAME").map { String(cString: $0) == rotulo } ?? false
        guard !peloLaunchd, getenv("NETWATCH_DIR") == nil, let h = getenv("HOME") else { return }
        let plist = String(cString: h) + "/Library/LaunchAgents/\(rotulo).plist"
        guard existe(plist) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "gui/\(getuid())/\(rotulo)"]
        if (try? p.run()) != nil {
            p.waitUntilExit()
            if p.terminationStatus == 0 { exit(0) }
        }
    }

    static func inicia() {
        let rotulo = Bundle.main.bundleIdentifier ?? "xyz.paralaxe.netwatch"
        redirecionaParaLaunchd(rotulo)

        guard var cfg = Config.padrao() else {
            fputs("netwatch: HOME nao definido\n", stderr)
            exit(2)
        }
        if let e = cfg.resolveAlvos() {
            fputs("netwatch: \(e)\n", stderr)
            exit(2)
        }
        criaPastas(cfg.dir)
        // uma instancia so: duas gravando duplicariam as amostras do samples.csv
        let trava = open(juntar(cfg.dir, "netwatch.lock"), O_CREAT | O_WRONLY, 0o644)
        if trava < 0 || flock(trava, LOCK_EX | LOCK_NB) != 0 {
            fputs("netwatch: ja tem outro aberto\n", stderr)
            exit(0)
        }
        guard let m = Monitor(cfg) else {
            fputs("netwatch: nao deu para abrir \(cfg.dir)\n", stderr)
            exit(1)
        }
        if let j = getenv("NETWATCH_JANELA").flatMap({ Int(String(cString: $0)) }) {
            m.janela = min(max(j, 0), JANELAS.count - 1)  // para testes, junto com NETWATCH_PNG
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if let t = getenv("NETWATCH_TEMA") {
            // para testes, junto com NETWATCH_PNG: "claro" ou "escuro"
            app.appearance = NSAppearance(named: String(cString: t) == "escuro" ? .darkAqua : .aqua)
        }

        let comum = Comum(m)
        self.comum = comum
        painel = Painel(janela: m.janela)
        menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = painel
        let it = NSMenuItem()
        it.view = painel
        menu.addItem(it)
        menu.addItem(.separator())
        menu.addItem(itemMenu("Abrir histórico de quedas", #selector(Acoes.abrirHistorico(_:)), ""))
        menu.addItem(itemMenu("Mostrar logs no Finder", #selector(Acoes.mostrarPasta(_:)), ""))
        menu.addItem(itemMenu("Configurações…", #selector(Acoes.abrirAjustes(_:)), ","))
        menu.addItem(.separator())
        menu.addItem(itemMenu("Sair do Netwatch", #selector(Acoes.sair(_:)), "q"))
        app.mainMenu = menuPrincipal()

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu

        let central = NSWorkspace.shared.notificationCenter
        observadores.append(central.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            log("mac indo dormir: medicao parada")
            MainActor.assumeIsolated { sonda.pausa() }
        })
        // Acordou de verdade (DidWake) ou a tela ligou (ScreensDidWake, que
        // tambem cobre um sono cancelado). Acordar de manutencao nao manda
        // nenhum dos dois, entao a medicao continua parada nele.
        for nome in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observadores.append(central.addObserver(forName: nome, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard sonda.estaParado else { return }
                    log("mac acordou: medicao retomada")
                    comum.com { c in
                        c.m.medindo = true
                        _ = barraMudou(c, aberto: true)
                        aplicaBarra(c.barra, c.m.faixas)
                    }
                    sonda.retoma()
                }
            })
        }
        comum.com { c in
            _ = barraMudou(c, aberto: true)
            aplicaBarra(c.barra, c.m.faixas)
        }

        let querPng = fundoDeTeste
        let querTeste = getenv("NETWATCH_TESTE_MENU") != nil || getenv("NETWATCH_TESTE_AJUSTES") != nil
        let modo: Sonda.Modo = getenv("NETWATCH_SONDA").map { String(cString: $0) } == "fio" ? .fio : .gcd
        sonda = Sonda(alvos: cfg.alvos, intervalo: cfg.intervalo, timeout: cfg.timeout, modo: modo) { a, alvo in
            let (acorda, png, teste) = comum.com { c -> (Bool, Bool, Bool) in
                c.m.registra(a, alvo: alvo)
                c.amostras += 1
                let aberto = c.menuAberto
                let png = querPng && c.amostras == 4
                let teste = querTeste && c.amostras == 3
                return (barraMudou(c, aberto: aberto) || aberto || png || teste, png, teste)
            }
            if acorda {
                DispatchQueue.main.async { MainActor.assumeIsolated { acordou(png: png, teste: teste) } }
            }
        }
        sonda.inicia()

        // SIGTERM (launchctl stop, logout), SIGINT e SIGHUP: grava o FIM antes
        // de sair. Pelo GCD, sem thread esperando sinal.
        for s: Int32 in [SIGTERM, SIGINT, SIGHUP] {
            signal(s, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
            src.setEventHandler { MainActor.assumeIsolated { () -> Void in encerrar() } }
            src.activate()
            sinais.append(src)
        }
    }
}

/// Alvo dos itens do menu.
@MainActor
final class Acoes: NSObject {
    static let shared = Acoes()

    private func caminho(_ nome: String) -> URL {
        URL(fileURLWithPath: juntar(App.comum.com { $0.m.cfg.dir }, nome))
    }

    @objc func abrirHistorico(_ sender: Any?) { NSWorkspace.shared.open(caminho("events.log")) }

    @objc func mostrarPasta(_ sender: Any?) { NSWorkspace.shared.activateFileViewerSelecting([caminho("samples.csv")]) }

    @objc func abrirAjustes(_ sender: Any?) { Ajustes.abrir() }

    @objc func sair(_ sender: Any?) { App.encerrar() }
}

MainActor.assumeIsolated { App.inicia() }
NSApplication.shared.run()
