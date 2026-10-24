// Janela de configuracoes: edita as faixas de cor do config.toml.
//
// Uma linha por faixa (limite em ms, cor do tema claro e do escuro). As
// linhas sao refeitas inteiras a cada mudanca de quantidade; ao salvar, grava
// o config.toml e aplica na hora no painel e na barra.
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
}

private struct Linha {
    var ms: NSTextField?
    var claro: NSColorWell
    var escuro: NSColorWell
}

@MainActor
final class Ajustes: NSObject, NSWindowDelegate {
    /// a janela aberta agora (nil quando fechada)
    private(set) static var aberta: Ajustes?

    let janela: NSWindow
    private let plano: Plano
    fileprivate var linhas: [Linha] = []
    private let erro = NSTextField(labelWithString: "")

    private override init() {
        let quadro = NSRect(x: 0, y: 0, width: LARGURA_A, height: 300)
        janela = NSWindow(contentRect: quadro, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        janela.isReleasedWhenClosed = false
        janela.title = "Netwatch — Configurações"
        plano = Plano(frame: quadro)
        janela.contentView = plano
        erro.textColor = .systemRed
        super.init()
        janela.delegate = self
    }

    /// Abre (ou traz para a frente) a janela, com as faixas em uso agora.
    static func abrir() {
        // O painel de cores abre nos controles RGB (com o campo hex). Aberto
        // na roda de cores, o AppKit desenha a roda inteira e o app passa de
        // 70 MB por alguns segundos; nos controles fica em ~24 MB. A roda
        // continua a um clique, na barra do painel.
        if !NSColorPanel.sharedColorPanelExists { NSColorPanel.setPickerMode(.RGB) }
        if aberta == nil {
            let a = Ajustes()
            a.monta(rascunhoDe(App.comum.com { $0.m.faixas }))
            a.janela.center()
            aberta = a
        }
        NSApp.activate(ignoringOtherApps: true)
        aberta?.janela.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // so mexe no painel de cores se ele ja existir: deactivate() e
        // NSColorPanel.shared criam o painel, que carrega uns 50 MB
        if NSColorPanel.sharedColorPanelExists {
            for l in linhas {
                l.claro.deactivate()
                l.escuro.deactivate()
            }
            NSColorPanel.shared.close()
        }
        // solta tudo no proximo giro do laco, depois que o AppKit terminar de fechar
        DispatchQueue.main.async {
            Ajustes.aberta = nil
            App.devolveMemoria()
        }
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
            if let e = grava(f) {
                mostraErro("Não deu para gravar o config.toml: \(e)")
                return
            }
            janela.close()
        case .failure(let e):
            mostraErro(e)
        }
    }

    // ------------------------------------------------------------ tela

    /// Le o que esta na tela agora, sem validar.
    private func leLinhas() -> [Rascunho] {
        linhas.map { Rascunho(ms: $0.ms?.stringValue, claro: componentes($0.claro.color), escuro: componentes($0.escuro.color)) }
    }

    /// Refaz todos os controles para estas linhas e ajusta a altura da janela.
    private func monta(_ rs: [Rascunho]) {
        for v in plano.subviews { v.removeFromSuperview() }
        func poe(_ v: NSView, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            v.frame = NSRect(x: x, y: y, width: w, height: h)
            plano.addSubview(v)
        }
        func rotulo(_ s: String, _ tam: CGFloat, _ negrito: Bool, _ cor: NSColor) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = negrito ? .boldSystemFont(ofSize: tam) : .systemFont(ofSize: tam)
            l.textColor = cor
            return l
        }
        func botao(_ titulo: String, _ acao: Selector) -> NSButton {
            NSButton(title: titulo, target: self, action: acao)
        }
        let sec = NSColor.secondaryLabelColor
        let lab = NSColor.labelColor

        poe(rotulo("Faixas de cor da latência", 13, true, lab), 20, 16, 380, 18)
        poe(rotulo("Cada faixa vale até o limite em ms; a última vale para o resto.", 11, false, sec), 20, 38, 390, 16)
        poe(rotulo("Até", 11, false, sec), 20, 70, 100, 16)
        poe(rotulo("Tema claro", 11, false, sec), X_CLARO, 70, 90, 16)
        poe(rotulo("Tema escuro", 11, false, sec), X_ESCURO, 70, 90, 16)

        var novas: [Linha] = []
        for (i, r) in rs.enumerated() {
            let y = TOPO_LINHAS + CGFloat(i) * ALTURA_LINHA
            var campo: NSTextField?
            if let txt = r.ms {
                let f = NSTextField(string: txt)
                f.alignment = .right
                poe(f, 20, y + 3, 70, 22)
                poe(rotulo("ms", 13, false, lab), 96, y + 5, 30, 18)
                campo = f
            } else {
                poe(rotulo("acima", 13, false, lab), 20, y + 5, 100, 18)
            }
            func poco(_ c: RGB, _ x: CGFloat) -> NSColorWell {
                let w = NSColorWell(style: .default)
                w.color = rgb(c)
                poe(w, x, y + 1, 64, 26)
                return w
            }
            let (claro, escuro) = (poco(r.claro, X_CLARO), poco(r.escuro, X_ESCURO))
            if campo != nil {
                let b = botao("−", #selector(remover(_:)))
                b.tag = i
                poe(b, 344, y + 1, 40, 26)
            }
            novas.append(Linha(ms: campo, claro: claro, escuro: escuro))
        }
        linhas = novas

        let ya = TOPO_LINHAS + CGFloat(rs.count) * ALTURA_LINHA + 6
        poe(botao("+ Adicionar faixa", #selector(adicionar(_:))), 16, ya, 150, 28)
        poe(botao("Abrir arquivo…", #selector(abrirArquivo(_:))), LARGURA_A - 16 - 130, ya, 130, 28)
        erro.stringValue = ""
        poe(erro, 20, ya + 38, LARGURA_A - 40, 16)
        let yr = ya + 64
        poe(botao("Restaurar padrão", #selector(restaurar(_:))), 16, yr, 140, 28)
        let cancelar = botao("Cancelar", #selector(cancelar(_:)))
        cancelar.keyEquivalent = "\u{1b}"
        poe(cancelar, LARGURA_A - 16 - 86 - 84, yr, 84, 28)
        let salvar = botao("Salvar", #selector(salvar(_:)))
        salvar.keyEquivalent = "\r"
        poe(salvar, LARGURA_A - 16 - 86, yr, 86, 28)

        janela.setContentSize(NSSize(width: LARGURA_A, height: yr + 28 + 18))
    }

    private func mostraErro(_ msg: String) { erro.stringValue = msg }

    /// Grava o config.toml e aplica no painel e na barra.
    private func grava(_ f: Faixas) -> String? {
        let caminho = juntar(App.comum.com { $0.m.cfg.dir }, "config.toml")
        if let e = escreveArquivo(caminho, textoConfig(f)) { return e }
        App.log("config.toml gravado pela janela de configuracoes")
        App.comum.com { c in
            c.m.leConfig()
            c.barra.classe = .max  // forca a barra a pegar as cores novas
            _ = barraMudou(c, aberto: c.menuAberto)
            App.aplicaBarra(c.barra, c.m.faixas)
        }
        App.painel.needsDisplay = true
        return nil
    }

    /// Para testes (NETWATCH_PNG + NETWATCH_PNG_AJUSTES): abre a janela e grava
    /// o conteudo dela em PNG. Com NETWATCH_PNG_AJUSTES=salvar, antes aperta
    /// "+ Adicionar faixa" e "Salvar", para exercitar o caminho de gravar.
    static func salvaPng(_ destino: String, salvar: Bool) {
        abrir()
        guard let a = aberta else { return }
        let plano = a.plano
        if salvar {
            a.adicionar(nil)
            a.salvar(nil)
        }
        App.salvaPng(plano, destino)
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
