// Janela de configuracoes, com abas na barra de ferramentas (como os ajustes
// dos apps do proprio macOS):
// - Cores: as faixas de cor do config.toml. Uma linha por faixa (limite em
//   ms, cor do tema claro e do escuro), refeitas inteiras a cada mudanca de
//   quantidade; ao salvar, grava o config.toml e aplica na hora no painel e
//   na barra.
// - Idioma: portugues, ingles ou o do sistema. Vale assim que escolhe.
// - Sobre: o que e o app, versao, licenca e o link do projeto.
//
// A janela nao fica guardada depois de fechada:
// ela, o painel de cores do sistema e os controles sao soltos e a memoria
// volta para o sistema (ver App.devolveMemoria).

import AppKit

private let LARGURA_A: CGFloat = 430
private let TOPO_LINHAS: CGFloat = 92
private let ALTURA_LINHA: CGFloat = 34
private let X_CLARO: CGFloat = 150
private let X_ESCURO: CGFloat = 250

/// coordenadas de cima para baixo, como o painel
final class Plano: NSView {
    override var isFlipped: Bool { true }

    func poe(_ v: NSView, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        v.frame = NSRect(x: x, y: y, width: w, height: h)
        addSubview(v)
    }
}

enum Aba: Int, CaseIterable {
    case cores, idioma, sobre

    var id: NSToolbarItem.Identifier { NSToolbarItem.Identifier("aba.\(rawValue)") }

    var titulo: String {
        switch self {
        case .cores: return tr("Cores", "Colors")
        case .idioma: return tr("Idioma", "Language")
        case .sobre: return tr("Sobre", "About")
        }
    }

    var simbolo: String {
        switch self {
        case .cores: return "paintpalette"
        case .idioma: return "globe"
        case .sobre: return "info.circle"
        }
    }

    /// NETWATCH_ABA=cores|idioma|sobre, para as capturas de tela
    static func de(_ nome: String) -> Aba? { allCases.first { "\($0)" == nome } }
}

private struct Linha {
    var ms: NSTextField?
    var claro: NSColorWell
    var escuro: NSColorWell
}

private func rotulo(_ s: String, _ tam: CGFloat, _ negrito: Bool, _ cor: NSColor) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = negrito ? .boldSystemFont(ofSize: tam) : .systemFont(ofSize: tam)
    l.textColor = cor
    return l
}

/// Texto que quebra linha na largura dada; devolve o campo e a altura.
private func paragrafo(_ s: String, _ tam: CGFloat, _ cor: NSColor, _ largura: CGFloat) -> (NSTextField, CGFloat) {
    let l = NSTextField(wrappingLabelWithString: s)
    l.font = .systemFont(ofSize: tam)
    l.textColor = cor
    l.isSelectable = false
    let h = l.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: largura, height: 1000)).height ?? 16
    return (l, ceil(h))
}

@MainActor
final class Ajustes: NSObject, NSWindowDelegate, NSToolbarDelegate {
    /// a janela aberta agora (nil quando fechada)
    private(set) static var aberta: Ajustes?

    let janela: NSWindow
    private var aba: Aba = .cores
    fileprivate var linhas: [Linha] = []
    /// as faixas da aba Cores ainda nao salvas: sobrevivem a troca de aba e de idioma
    private var rascunho: [Rascunho]
    private let erro = NSTextField(labelWithString: "")

    private init(_ rascunho: [Rascunho]) {
        self.rascunho = rascunho
        let quadro = NSRect(x: 0, y: 0, width: LARGURA_A, height: 300)
        janela = NSWindow(contentRect: quadro, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        janela.isReleasedWhenClosed = false
        janela.toolbarStyle = .preference
        erro.textColor = .systemRed
        super.init()
        janela.delegate = self
        let barra = NSToolbar(identifier: "ajustes")
        barra.delegate = self
        barra.displayMode = .iconAndLabel
        barra.allowsUserCustomization = false
        janela.toolbar = barra
    }

    /// Abre (ou traz para a frente) a janela, com as faixas em uso agora.
    static func abrir(_ aba: Aba = .cores, mostrar: Bool = true) {
        // O painel de cores abre nos controles RGB (com o campo hex). Aberto
        // na roda de cores, o AppKit desenha a roda inteira e o app passa de
        // 70 MB por alguns segundos; nos controles fica em ~24 MB. A roda
        // continua a um clique, na barra do painel.
        if !NSColorPanel.sharedColorPanelExists { NSColorPanel.setPickerMode(.RGB) }
        if aberta == nil {
            let a = Ajustes(rascunhoDe(App.comum.com { $0.m.faixas }))
            a.mostra(aba)
            a.janela.center()
            aberta = a
        } else if aberta?.aba != aba {
            aberta?.mostra(aba)
        }
        if !mostrar { return }
        NSApp.activate(ignoringOtherApps: true)
        aberta?.janela.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        soltaPocos()
        // solta tudo no proximo giro do laco, depois que o AppKit terminar de fechar
        DispatchQueue.main.async {
            Ajustes.aberta = nil
            App.devolveMemoria()
        }
    }

    /// So mexe no painel de cores se ele ja existir: deactivate() e
    /// NSColorPanel.shared criam o painel, que carrega uns 50 MB.
    private func soltaPocos() {
        guard NSColorPanel.sharedColorPanelExists else { return }
        for l in linhas {
            l.claro.deactivate()
            l.escuro.deactivate()
        }
        NSColorPanel.shared.close()
    }

    // ------------------------------------------------------------ abas

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Aba.allCases.map(\.id) }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Aba.allCases.map(\.id) }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Aba.allCases.map(\.id) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let a = Aba.allCases.first(where: { $0.id == id }) else { return nil }
        let it = NSToolbarItem(itemIdentifier: id)
        it.label = a.titulo
        it.image = NSImage(systemSymbolName: a.simbolo, accessibilityDescription: nil)
        it.target = self
        it.action = #selector(escolheAba(_:))
        return it
    }

    @objc func escolheAba(_ sender: NSToolbarItem) {
        if let a = Aba.allCases.first(where: { $0.id == sender.itemIdentifier }), a != aba { mostra(a) }
    }

    /// Troca o conteudo da janela para esta aba.
    private func mostra(_ a: Aba) {
        if aba == .cores && !linhas.isEmpty {
            rascunho = leLinhas()
            soltaPocos()
        }
        linhas = []
        aba = a
        janela.title = a.titulo
        janela.toolbar?.selectedItemIdentifier = a.id
        switch a {
        case .cores: monta(rascunho)
        case .idioma: montaIdioma()
        case .sobre: montaSobre()
        }
    }

    /// Acerta a altura, mantendo o topo no lugar, e poe o plano na janela.
    /// A conta e pela diferenca: frameRect(forContentRect:) nao conta a
    /// barra de abas.
    private func troca(_ p: Plano, altura: CGFloat) {
        let delta = altura - (janela.contentView?.frame.height ?? altura)
        var f = janela.frame
        f.size.height += delta
        f.origin.y -= delta
        janela.setFrame(f, display: true, animate: janela.isVisible)
        p.frame = NSRect(x: 0, y: 0, width: LARGURA_A, height: altura)
        janela.contentView = p
    }

    /// O idioma mudou: textos novos na barra de abas e na aba aberta.
    func traduz() {
        for it in janela.toolbar?.items ?? [] {
            if let a = Aba.allCases.first(where: { $0.id == it.itemIdentifier }) { it.label = a.titulo }
        }
        mostra(aba)
    }

    // ------------------------------------------------------------ acoes

    @objc func adicionar(_ sender: Any?) {
        var r = leLinhas()
        let maior = r.compactMap { $0.ms.flatMap(numero) }.max() ?? 0
        let ultima = r.last.map { ($0.claro, $0.escuro) } ?? (RGB(0x88, 0x88, 0x88), RGB(0x88, 0x88, 0x88))
        r.insert(Rascunho(ms: formataMs(maior + 100), claro: ultima.0, escuro: ultima.1), at: max(r.count - 1, 0))
        monta(r)
    }

    @objc func remover(_ sender: NSButton) {
        var r = leLinhas()
        let i = sender.tag
        if i + 1 < r.count {
            r.remove(at: i)
            monta(r)
        }
    }

    @objc func restaurar(_ sender: Any?) { monta(rascunhoDe(.padrao)) }

    @objc func abrirArquivo(_ sender: Any?) {
        let p = juntar(App.comum.com { $0.m.cfg.dir }, "config.toml")
        if !existe(p) { _ = escreveArquivo(p, textoConfig(.padrao)) }
        // -t: editor de texto padrao (um .toml pode nao ter app associado)
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        t.arguments = ["-t", p]
        try? t.run()
    }

    @objc func cancelar(_ sender: Any?) { janela.close() }

    @objc func salvar(_ sender: Any?) {
        switch valida(leLinhas()) {
        case .success(let f):
            if let e = grava(textoConfig(f, idioma: App.comum.com { $0.m.idioma })) {
                mostraErro(tr("Não deu para gravar o config.toml: \(e)", "Couldn't save config.toml: \(e)"))
                return
            }
            janela.close()
        case .failure(let e):
            mostraErro(e)
        }
    }

    @objc func escolheIdioma(_ sender: NSPopUpButton) {
        // 0 = automatico, 1 = o separador, 2... = Idioma.allCases
        let i = sender.indexOfSelectedItem
        let novo: Idioma? = i >= 2 ? Idioma.allCases[i - 2] : nil
        // Com o config.toml certo, regrava inteiro, com os comentarios no
        // idioma novo. Com erro, so troca a linha do idioma: regravar poria
        // as faixas padrao no lugar das que a pessoa esta consertando.
        let texto = App.comum.com { c -> String? in
            if novo == c.m.idioma { return nil }
            if c.m.erroConfig != nil { return trocaIdioma(leArquivo(juntar(c.m.cfg.dir, "config.toml")) ?? "", novo) }
            let antes = idiomaAtual
            idiomaAtual = idiomaEfetivo(novo)
            defer { idiomaAtual = antes }
            return textoConfig(c.m.faixas, idioma: novo)
        }
        guard let texto else { return }
        // depois do clique: a troca refaz a aba, com este popup junto
        DispatchQueue.main.async {
            if let e = self.grava(texto) {
                self.mostraErro(tr("Não deu para gravar o config.toml: \(e)", "Couldn't save config.toml: \(e)"))
            }
        }
    }

    @objc func abrirSite(_ sender: Any?) {
        if let u = URL(string: SITE) { NSWorkspace.shared.open(u) }
    }

    @objc func abrirPasta(_ sender: Any?) { Acoes.shared.mostrarPasta(sender) }

    // ------------------------------------------------------------ cores

    /// Le o que esta na tela agora, sem validar.
    private func leLinhas() -> [Rascunho] {
        linhas.map { Rascunho(ms: $0.ms?.stringValue, claro: componentes($0.claro.color), escuro: componentes($0.escuro.color)) }
    }

    private func botao(_ titulo: String, _ acao: Selector) -> NSButton {
        NSButton(title: titulo, target: self, action: acao)
    }

    /// Refaz todos os controles da aba Cores para estas linhas e ajusta a
    /// altura da janela.
    private func monta(_ rs: [Rascunho]) {
        soltaPocos()
        let p = Plano()
        let sec = NSColor.secondaryLabelColor
        let lab = NSColor.labelColor

        p.poe(rotulo(tr("Faixas de cor da latência", "Latency color bands"), 13, true, lab), 20, 16, 380, 18)
        p.poe(rotulo(tr("Cada faixa vale até o limite em ms; a última vale para o resto.",
                        "Each band applies up to its limit in ms; the last one covers the rest."), 11, false, sec),
              20, 38, 400, 16)
        p.poe(rotulo(tr("Até", "Up to"), 11, false, sec), 20, 70, 100, 16)
        p.poe(rotulo(tr("Tema claro", "Light mode"), 11, false, sec), X_CLARO, 70, 90, 16)
        p.poe(rotulo(tr("Tema escuro", "Dark mode"), 11, false, sec), X_ESCURO, 70, 90, 16)

        var novas: [Linha] = []
        for (i, r) in rs.enumerated() {
            let y = TOPO_LINHAS + CGFloat(i) * ALTURA_LINHA
            var campo: NSTextField?
            if let txt = r.ms {
                let f = NSTextField(string: txt)
                f.alignment = .right
                p.poe(f, 20, y + 3, 70, 22)
                p.poe(rotulo("ms", 13, false, lab), 96, y + 5, 30, 18)
                campo = f
            } else {
                p.poe(rotulo(tr("acima", "above"), 13, false, lab), 20, y + 5, 100, 18)
            }
            func poco(_ c: RGB, _ x: CGFloat) -> NSColorWell {
                let w = NSColorWell(style: .default)
                w.color = rgb(c)
                p.poe(w, x, y + 1, 64, 26)
                return w
            }
            let (claro, escuro) = (poco(r.claro, X_CLARO), poco(r.escuro, X_ESCURO))
            if campo != nil {
                let b = botao("−", #selector(remover(_:)))
                b.tag = i
                p.poe(b, 344, y + 1, 40, 26)
            }
            novas.append(Linha(ms: campo, claro: claro, escuro: escuro))
        }
        linhas = novas

        let ya = TOPO_LINHAS + CGFloat(rs.count) * ALTURA_LINHA + 6
        p.poe(botao(tr("+ Adicionar faixa", "+ Add band"), #selector(adicionar(_:))), 16, ya, 150, 28)
        p.poe(botao(tr("Abrir arquivo…", "Open file…"), #selector(abrirArquivo(_:))), LARGURA_A - 16 - 130, ya, 130, 28)
        erro.stringValue = ""
        p.poe(erro, 20, ya + 38, LARGURA_A - 40, 16)
        let yr = ya + 64
        p.poe(botao(tr("Restaurar padrão", "Restore defaults"), #selector(restaurar(_:))), 16, yr, 150, 28)
        let cancelar = botao(tr("Cancelar", "Cancel"), #selector(cancelar(_:)))
        cancelar.keyEquivalent = "\u{1b}"
        p.poe(cancelar, LARGURA_A - 16 - 86 - 84, yr, 84, 28)
        let salvar = botao(tr("Salvar", "Save"), #selector(salvar(_:)))
        salvar.keyEquivalent = "\r"
        p.poe(salvar, LARGURA_A - 16 - 86, yr, 86, 28)

        troca(p, altura: yr + 28 + 18)
    }

    private func mostraErro(_ msg: String) { erro.stringValue = msg }

    /// Grava o config.toml e aplica no painel, na barra e, se o idioma
    /// mudou, em todos os textos.
    private func grava(_ texto: String) -> String? {
        let caminho = juntar(App.comum.com { $0.m.cfg.dir }, "config.toml")
        if let e = escreveArquivo(caminho, texto) { return e }
        App.log("config.toml gravado pela janela de configuracoes")
        let mudouIdioma = App.comum.com { c -> Bool in
            let antes = idiomaAtual
            c.m.leConfig()
            c.barra.classe = .max  // forca a barra a pegar as cores novas
            _ = barraMudou(c, aberto: c.menuAberto)
            App.aplicaBarra(c.barra, c.m.faixas)
            return antes != idiomaAtual
        }
        App.painel.needsDisplay = true
        if mudouIdioma {
            App.idiomaMudou()
        } else if aba == .idioma {
            mostra(.idioma)  // "Automatico (...)" pode ter mudado de nome
        }
        return nil
    }

    // ------------------------------------------------------------ idioma

    private func montaIdioma() {
        let p = Plano()
        let sec = NSColor.secondaryLabelColor
        let w = LARGURA_A - 40
        p.poe(rotulo(tr("Idioma do app", "App language"), 13, true, .labelColor), 20, 16, w, 18)

        let pop = NSPopUpButton(frame: .zero, pullsDown: false)
        let nomes: [Idioma: String] = [.pt: "Português", .en: "English"]
        let sistema = nomes[idiomaDoSistema()] ?? ""
        pop.addItem(withTitle: tr("Automático (\(sistema))", "Automatic (\(sistema))"))
        pop.menu?.addItem(.separator())
        for i in Idioma.allCases { pop.addItem(withTitle: nomes[i] ?? i.rawValue) }
        let atual = App.comum.com { $0.m.idioma }
        // o separador ocupa o indice 1
        pop.selectItem(at: atual.flatMap { Idioma.allCases.firstIndex(of: $0) }.map { $0 + 2 } ?? 0)
        pop.target = self
        pop.action = #selector(escolheIdioma(_:))
        p.poe(pop, 18, 44, 220, 26)

        var y: CGFloat = 84
        for s in [
            tr("Automático segue o idioma do macOS (Ajustes do Sistema → Geral → Idioma e Região).",
               "Automatic follows the macOS language (System Settings → General → Language & Region)."),
            tr("A troca vale na hora para o menu, o painel e o histórico de quedas, e fica guardada no config.toml.",
               "The change applies right away to the menu, the panel and the outage history, and is saved in config.toml."),
        ] {
            let (l, h) = paragrafo(s, 11, sec, w)
            p.poe(l, 20, y, w, h)
            y += h + 8
        }
        erro.stringValue = ""
        p.poe(erro, 20, y, w, 16)
        troca(p, altura: y + 16 + 14)
    }

    // ------------------------------------------------------------ sobre

    private func montaSobre() {
        let p = Plano()
        let sec = NSColor.secondaryLabelColor
        let w = LARGURA_A - 40
        let versao = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let verde = App.comum.com { $0.m.faixas.corDe(0, escuro: eEscura(janela.effectiveAppearance)) }

        let bola = rotulo("●", 34, false, rgb(verde))
        p.poe(bola, 18, 14, 40, 42)
        p.poe(rotulo(NOME_APP, 17, true, .labelColor), 62, 18, w - 42, 22)
        p.poe(rotulo(tr("Versão \(versao)", "Version \(versao)"), 11, false, sec), 62, 40, w - 42, 16)

        var y: CGFloat = 76
        let textos: [(String, NSColor)] = [
            (tr("Mostra na barra de menus se a internet está funcionando agora e guarda um registro de cada queda.",
                "Shows in the menu bar whether your internet is working right now, and keeps a record of every outage."),
             .labelColor),
            (tr("Feito para ficar aberto o dia todo sem pesar: cerca de 12 MB de memória, impacto de energia 0,0 e um teste TCP pequeno a cada 2 segundos.",
                "Built to run all day without weighing on your Mac: about 12 MB of memory, 0.0 Energy Impact and one small TCP test every 2 seconds."),
             .labelColor),
            (tr("Os registros ficam só no seu Mac, em ~/.netwatch. O app não envia nenhum dado: só abre e fecha uma conexão com 1.1.1.1.",
                "Your logs stay on your Mac, in ~/.netwatch. The app sends no data: it only opens and closes a connection to 1.1.1.1."),
             sec),
        ]
        for (s, cor) in textos {
            let (l, h) = paragrafo(s, 12, cor, w)
            p.poe(l, 20, y, w, h)
            y += h + 10
        }
        y += 4
        p.poe(botao(tr("Ver no GitHub", "View on GitHub"), #selector(abrirSite(_:))), 16, y, 150, 28)
        p.poe(botao(tr("Mostrar dados no Finder", "Show data in Finder"), #selector(abrirPasta(_:))), 170, y, 190, 28)
        y += 40
        p.poe(rotulo(tr("Código aberto, licença MIT · © 2026 seupedro", "Open source, MIT License · © 2026 seupedro"),
                     11, false, sec), 20, y, w, 16)
        troca(p, altura: y + 16 + 18)
    }

    // ------------------------------------------------------------ testes

    /// Para testes (NETWATCH_PNG + NETWATCH_PNG_AJUSTES): abre a janela na aba
    /// de NETWATCH_ABA, sem mostrar na tela, e grava a imagem dela (com a
    /// barra de abas) em PNG. Os pocos de cor saem com um quadrado branco em
    /// volta (so na imagem; nao some nem com a janela na tela e ativa), que
    /// quase nao aparece no tema claro. Modos:
    /// - salvar: antes aperta "+ Adicionar faixa" e "Salvar";
    /// - trocar: escolhe o outro idioma no popup da aba Idioma, como o
    ///   usuario faria, e a imagem sai depois da troca.
    static func salvaPng(_ destino: String, modo: String, fim: @escaping () -> Void) {
        var aba = getenv("NETWATCH_ABA").flatMap { Aba.de(String(cString: $0)) } ?? .cores
        if modo == "trocar" { aba = .idioma }
        abrir(aba, mostrar: false)
        guard let a = aberta else { return fim() }
        func grava() {
            if let v = a.janela.contentView?.superview ?? a.janela.contentView { App.salvaPng(v, destino) }
            fim()
        }
        switch modo {
        case "salvar":
            a.adicionar(nil)
            a.salvar(nil)
            grava()
        case "trocar":
            guard let pop = a.janela.contentView?.subviews.lazy.compactMap({ $0 as? NSPopUpButton }).first,
                  let k = Idioma.allCases.firstIndex(of: idiomaAtual == .en ? .pt : .en) else { return fim() }
            pop.selectItem(at: k + 2)
            a.escolheIdioma(pop)
            // a troca roda no proximo giro do laco
            DispatchQueue.main.async {
                App.log("menu depois da troca: " + App.itensComTexto.map(\.title).joined(separator: " | "))
                grava()
            }
        default:
            grava()
        }
    }
}

extension Ajustes {
    /// Para testes: clica no primeiro poco de cor, como o usuario faria.
    func clicaPrimeiroPoco() { linhas.first?.claro.performClick(nil) }
}

private func componentes(_ c: NSColor) -> RGB {
    guard let s = c.usingColorSpace(.sRGB) else { return RGB(0x88, 0x88, 0x88) }
    let b = { (v: CGFloat) -> UInt8 in UInt8((min(max(v, 0), 1) * 255).rounded()) }
    return RGB(b(s.redComponent), b(s.greenComponent), b(s.blueComponent))
}
