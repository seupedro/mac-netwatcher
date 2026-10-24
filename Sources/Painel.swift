// O painel do menu, desenhado a mao (sem WebView, sem HTML). So e desenhado
// com o menu aberto.

import AppKit

let LARGURA: CGFloat = 440
let ALTURA: CGFloat = 412
let MARGEM: CGFloat = 16
/// Colunas do grafico por janela (JANELAS): 1m = 2 s cada (uma amostra),
/// 5m = 6 s (~3 amostras: um pico isolado fica so na faixa), 15m = 10 s,
/// 1h = 40 s, 6h = 4 min, 24h = 16 min.
let COLUNAS = [30, 50, 90, 90, 90, 90]

// ---------------------------------------------------------------- desenho

enum Peso { case normal, medio, forte }

func fonte(_ tam: CGFloat, _ peso: Peso) -> NSFont {
    let w: NSFont.Weight = peso == .normal ? .regular : peso == .medio ? .medium : .semibold
    return .monospacedDigitSystemFont(ofSize: tam, weight: w)
}

/// Texto com o canto superior esquerdo em (x, y). `alinha` 0 = esquerda,
/// 0.5 = centro, 1 = direita em relacao a x. Devolve a largura.
@discardableResult
func texto(_ s: String, _ x: CGFloat, _ y: CGFloat, _ alinha: CGFloat, _ f: NSFont, _ cor: NSColor) -> CGFloat {
    let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: cor]
    let ns = s as NSString
    let w = alinha == 0 ? 0 : ns.size(withAttributes: a).width
    ns.draw(at: NSPoint(x: x - w * alinha, y: y), withAttributes: a)
    return w
}

func retangulo(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ cor: NSColor) {
    cor.setFill()
    NSBezierPath.fill(NSRect(x: x, y: y, width: w, height: h))
}

func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

func rgb(_ c: RGB, _ a: CGFloat = 1) -> NSColor { rgb(c.r, c.g, c.b, a) }

func eEscura(_ a: NSAppearance) -> Bool {
    a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
}

func temaEscuro() -> Bool { eEscura(NSAppearance.currentDrawing()) }

/// Cores solidas por tema. As semanticas do sistema (secondaryLabelColor e
/// cia.) sao translucidas e somem sobre o vidro do menu.
struct Paleta {
    var area, grade, vazio, banda, texto, texto2, eixo, verde, amarelo, vermelho: NSColor
    /// uma por faixa do config.toml, no tema atual
    var faixas: [NSColor]
    var limites: Faixas

    init(_ f: Faixas) {
        let escuro = temaEscuro()
        faixas = f.lista.indices.map { rgb(f.corDe($0, escuro: escuro)) }
        limites = f
        if escuro {
            area = rgb(255, 255, 255, 0.05)
            grade = rgb(255, 255, 255, 0.13)
            vazio = rgb(255, 255, 255, 0.10)
            banda = rgb(255, 255, 255, 0.16)
            texto = rgb(245, 245, 247)
            texto2 = rgb(204, 204, 210)
            eixo = rgb(162, 162, 170)
            verde = rgb(48, 209, 88)
            amarelo = rgb(255, 204, 0)
            vermelho = rgb(255, 105, 97)
        } else {
            area = rgb(0, 0, 0, 0.035)
            grade = rgb(0, 0, 0, 0.10)
            vazio = rgb(0, 0, 0, 0.08)
            banda = rgb(0, 0, 0, 0.10)
            texto = rgb(29, 29, 31)
            texto2 = rgb(58, 58, 64)
            eixo = rgb(88, 88, 96)
            verde = rgb(22, 128, 56)
            amarelo = rgb(176, 106, 0)
            vermelho = rgb(200, 36, 36)
        }
    }

    func ms(_ v: Float) -> NSColor { faixas[limites.indice(v)] }
}

/// Tangentes de uma curva monotona por partes (Fritsch-Carlson): a curva
/// passa por todos os pontos sem inventar picos ou vales entre eles.
func tangentes(_ p: [NSPoint]) -> [CGFloat] {
    let n = p.count
    if n < 2 { return [CGFloat](repeating: 0, count: n) }
    let d = (0..<n - 1).map { (p[$0 + 1].y - p[$0].y) / (p[$0 + 1].x - p[$0].x) }
    var m = [CGFloat](repeating: 0, count: n)
    m[0] = d[0]
    m[n - 1] = d[n - 2]
    for i in stride(from: 1, to: n - 1, by: 1) {
        m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2
    }
    for i in 0..<n - 1 {
        if d[i] == 0 {
            m[i] = 0
            m[i + 1] = 0
            continue
        }
        let (a, b) = (m[i] / d[i], m[i + 1] / d[i])
        let s = a * a + b * b
        if s > 9 {
            let t = 3 / s.squareRoot()
            m[i] = t * a * d[i]
            m[i + 1] = t * b * d[i]
        }
    }
    return m
}

/// Curva cubica de `a` ate `b` com as tangentes dadas (Hermite em Bezier).
func curvaAte(_ c: NSBezierPath, _ a: NSPoint, _ ta: CGFloat, _ b: NSPoint, _ tb: CGFloat) {
    let h = (b.x - a.x) / 3
    c.curve(to: b, controlPoint1: NSPoint(x: a.x + h, y: a.y + ta * h),
            controlPoint2: NSPoint(x: b.x - h, y: b.y - tb * h))
}

func desenhaPainel(_ m: Monitor, fundoDeTeste: Bool) {
    let agora = agora()
    let qs = quedas(m, agora)
    let (jan, nome) = JANELAS[m.janela]
    let r = resumo(m, qs, agora, jan)
    let p = Paleta(m.faixas)
    let rotulo = fonte(10, .normal)
    if fundoDeTeste {
        // para testes: a imagem sai transparente; um cinza parecido com o do
        // menu deixa julgar o contraste
        retangulo(0, 0, LARGURA, ALTURA, temaEscuro() ? rgb(44, 44, 46) : rgb(232, 232, 234))
    }

    // cabecalho: latencia grande e o estado embaixo
    let grande: String, cor: NSColor, sub: String
    if m.medindo {
        (grande, cor, sub) = ("…", p.eixo, "medindo")
    } else if !m.online {
        (grande, cor, sub) = ("Sem conexão", p.vermelho,
                              "há \(dur(agora - m.caiuEm)) · desde \(fmt(m.caiuEm, "%H:%M:%S"))")
    } else if let u = m.ultimo {
        (grande, cor, sub) = ("\(Int(u.ms.rounded())) ms", p.ms(u.ms), "online · via \(m.cfg.alvos[u.alvo].ip)")
    } else {
        (grande, cor, sub) = ("…", p.eixo, "")
    }
    texto(grande, MARGEM, 10, 0, fonte(22, .forte), cor)
    if let e = m.erroConfig {
        let curto = e.count > 60 ? String(e.prefix(59)) + "…" : e
        texto("⚠ \(curto)", MARGEM, 38, 0, fonte(11, .medio), p.vermelho)
    } else {
        texto(sub, MARGEM, 38, 0, fonte(11, .normal), p.texto2)
    }

    // grafico: as amostras sao agrupadas em colunas (mediana e quartis) e
    // ligadas por curvas suaves; com centenas de pontos ruidosos a linha
    // ficava so ponta
    let (gx, gy, gw, gh): (CGFloat, CGFloat, CGFloat, CGFloat) = (MARGEM + 34, 64, LARGURA - MARGEM * 2 - 34, 150)
    let (t0, t1) = (agora - jan, agora)
    let n = COLUNAS[m.janela]
    let bs = baldes(m, t0: t0, jan: jan, n: n)
    let ymax = CGFloat(escalaPara(bs.reduce(Float(0)) { max($0, $1?.q3 ?? 0) }))
    let px = { (t: Double) -> CGFloat in gx + CGFloat(min(max((t - t0) / jan, 0), 1)) * gw }
    let py = { (v: Float) -> CGFloat in gy + gh - min(CGFloat(v), ymax) / ymax * gh }

    p.area.setFill()
    NSBezierPath(roundedRect: NSRect(x: gx, y: gy, width: gw, height: gh), xRadius: 4, yRadius: 4).fill()

    let passo = CGFloat(passoGrade(Float(ymax)))
    let linhas = Int((ymax / passo).rounded())
    for i in 0...max(linhas, 0) {
        let v = passo * CGFloat(i)
        let y = gy + gh - v / ymax * gh
        if i > 0 && i < linhas { retangulo(gx, y, gw, 0.5, p.grade) }
        texto(numTexto(Double(v.rounded())), gx - 6, y - 6.5, 1, rotulo, p.eixo)
    }

    let vermelhoFraco = p.vermelho.withAlphaComponent(0.18)
    for q in qs where q.fim >= t0 && q.ini <= t1 {
        let (a, b) = (px(q.ini), px(q.fim))
        retangulo(a, gy, max(b - a, 1.5), gh, vermelhoFraco)
        retangulo(a, gy + gh - 3, max(b - a, 1.5), 3, p.vermelho)
    }

    // Trechos continuos: a curva so quebra quando passa mais de ~10 s sem
    // nenhuma resposta (queda ou Mac parado). Coluna vazia por atraso de um
    // teste nao quebra, e falha isolada tambem nao: a queda ja aparece na
    // faixa vermelha, e quebrar em toda falha picotaria a curva.
    let coluna = jan / Double(n)
    let lacuna = max(m.cfg.intervalo * 2 + m.cfg.timeout * 2, coluna * 1.5)
    var trechos: [[(x: CGFloat, b: Balde)]] = []
    var ant: Int?
    for (i, b) in bs.enumerated() {
        guard let b else { continue }
        let continua = ant.map { Double(i - $0) * coluna <= lacuna } ?? false
        if !continua || trechos.isEmpty { trechos.append([]) }
        trechos[trechos.count - 1].append((gx + (CGFloat(i) + 0.5) / CGFloat(n) * gw, b))
        ant = i
    }

    // faixa de variacao: entre o 1o e o 3o quartil de cada coluna
    p.banda.setFill()
    for t in trechos where t.count >= 2 {
        let cima = t.map { NSPoint(x: $0.x, y: py($0.b.q3)) }
        let baixo = t.map { NSPoint(x: $0.x, y: py($0.b.q1)) }
        let (tc, tb) = (tangentes(cima), tangentes(baixo))
        let c = NSBezierPath()
        c.move(to: cima[0])
        for i in 1..<cima.count { curvaAte(c, cima[i - 1], tc[i - 1], cima[i], tc[i]) }
        let k = baixo.count - 1
        c.line(to: baixo[k])
        for i in stride(from: k - 1, through: 0, by: -1) { curvaAte(c, baixo[i + 1], tb[i + 1], baixo[i], tb[i]) }
        c.close()
        c.fill()
    }

    // linha da mediana, com area preenchida embaixo
    let areaCor = p.verde.withAlphaComponent(0.12)
    for t in trechos {
        let pts = t.map { NSPoint(x: $0.x, y: py($0.b.med)) }
        let tg = tangentes(pts)
        if pts.count >= 2 {
            let c = NSBezierPath()
            c.move(to: NSPoint(x: pts[0].x, y: gy + gh))
            c.line(to: pts[0])
            for i in 1..<pts.count { curvaAte(c, pts[i - 1], tg[i - 1], pts[i], tg[i]) }
            c.line(to: NSPoint(x: pts[pts.count - 1].x, y: gy + gh))
            c.close()
            areaCor.setFill()
            c.fill()
        }
        for i in pts.indices.dropFirst() {
            let c = NSBezierPath()
            c.lineWidth = 1.8
            c.lineCapStyle = .round
            c.lineJoinStyle = .round
            c.move(to: pts[i - 1])
            curvaAte(c, pts[i - 1], tg[i - 1], pts[i], tg[i])
            p.ms(t[i].b.med).setStroke()
            c.stroke()
        }
        if pts.count == 1 { retangulo(pts[0].x - 1, pts[0].y - 1, 2, 2, p.ms(t[0].b.med)) }
    }
    if let u = trechos.last?.last {
        let y = py(u.b.med)
        p.ms(u.b.med).setFill()
        NSBezierPath(ovalIn: NSRect(x: u.x - 3, y: y - 3, width: 6, height: 6)).fill()
    }
    if r.amostras == 0 {
        texto("sem medições nesta janela", gx + gw / 2, gy + gh / 2 - 7, 0.5, fonte(11, .normal), p.eixo)
    }

    let f = jan <= 900 ? "%H:%M:%S" : "%H:%M"
    let ey = gy + gh + 4
    texto(fmt(t0, f), gx, ey, 0, rotulo, p.eixo)
    texto(fmt((t0 + t1) / 2, f), gx + gw / 2, ey, 0.5, rotulo, p.eixo)
    texto("agora", gx + gw, ey, 1, rotulo, p.eixo)

    // faixa das ultimas 24h
    let fy: CGFloat = 240
    let titulo = fonte(11, .forte)
    texto("Últimas 24 h", MARGEM, fy, 0, titulo, p.texto2)
    let (sx, sw) = (MARGEM, LARGURA - MARGEM * 2)
    let ncol = Int(sw / 3)
    let cw = sw / CGFloat(ncol)
    var transparentes: [Int: NSColor] = [:]  // uma cor com alfa por faixa, nao uma por coluna
    for (i, c) in colunas24h(m, agora, ncol).enumerated() {
        let cor: NSColor
        switch c {
        case .semDado: cor = p.vazio
        case .falhou: cor = p.vermelho
        case .mediana(let ms):
            let k = p.limites.indice(ms)
            if transparentes[k] == nil { transparentes[k] = p.faixas[k].withAlphaComponent(0.85) }
            cor = transparentes[k]!
        }
        retangulo(sx + CGFloat(i) * cw, fy + 18, cw - 1, 12, cor)
    }
    // a marca colada na borda direita sairia cortada
    for (pos, txt) in marcasHora(agora, 3) where pos < 0.96 {
        texto(txt, sx + CGFloat(pos) * sw, fy + 33, 0, rotulo, p.eixo)
    }

    // numeros da janela e quedas recentes
    let ny: CGFloat = 300
    retangulo(MARGEM, ny - 10, LARGURA - MARGEM * 2, 0.5, p.grade)
    texto("Janela \(nome)", MARGEM, ny, 0, titulo, p.texto2)
    let normal = fonte(12, .normal)
    let forte = fonte(12, .medio)
    func linha(_ i: Int, _ chave: String, _ valor: String, _ cor: NSColor) {
        let y = ny + 20 + CGFloat(i) * 18
        texto(chave, MARGEM, y, 0, normal, p.texto2)
        texto(valor, MARGEM + 72, y, 0, forte, cor)
    }
    let up = r.onlinePct
    let corUp = up >= 99.5 ? p.verde : up >= 95 ? p.amarelo : p.vermelho
    linha(0, "Online", "\(umaCasa(Float(up)))%  ·  \(r.amostras) amostras", corUp)
    linha(1, "Quedas", "\(r.quedas)  ·  \(dur(r.fora)) fora", r.quedas > 0 ? p.vermelho : p.texto)
    if !r.lat.isEmpty {
        let med = pct(r.lat, 50)
        linha(2, "Mediana", "\(Int(med.rounded())) ms  ·  p95 \(Int(pct(r.lat, 95).rounded()))", p.ms(med))
        linha(3, "Mín–máx", "\(Int(r.lat[0].rounded())) – \(Int(r.lat[r.lat.count - 1].rounded())) ms", p.texto)
    }
    linha(4, "Sessão", "\(dur(agora - m.inicio))  ·  \(nQuedas(m.quedas))", p.texto)

    let qx = LARGURA / 2 + 24
    texto("Quedas em 24 h · \(qs.count)", qx, ny, 0, titulo, p.texto2)
    if qs.isEmpty { texto("nenhuma", qx, ny + 20, 0, normal, p.verde) }
    let hoje = fmt(agora, "%Y%m%d")
    for (i, q) in qs.reversed().prefix(5).enumerated() {
        let y = ny + 20 + CGFloat(i) * 18
        let quando = fmt(q.ini, "%Y%m%d") == hoje ? fmt(q.ini, "%H:%M:%S") : fmt(q.ini, "%d/%m %H:%M")
        texto(quando, qx, y, 0, normal, p.texto2)
        if q.emCurso {
            texto("em curso", LARGURA - MARGEM, y, 1, forte, p.vermelho)
        } else {
            texto(dur(q.fim - q.ini), LARGURA - MARGEM, y, 1, forte, p.texto)
        }
    }
}

// ---------------------------------------------------------------- vista

final class Painel: NSView, NSMenuDelegate {
    override var isFlipped: Bool { true }

    init(janela: Int) {
        super.init(frame: NSRect(x: 0, y: 0, width: LARGURA, height: ALTURA))
        let seg = NSSegmentedControl(labels: JANELAS.map(\.nome), trackingMode: .selectOne,
                                     target: self, action: #selector(mudaJanela(_:)))
        seg.controlSize = .small
        seg.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        seg.selectedSegment = janela
        seg.sizeToFit()
        seg.setFrameOrigin(NSPoint(x: LARGURA - MARGEM - seg.frame.width, y: 16))
        addSubview(seg)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        App.comum.com { c in desenhaPainel(c.m, fundoDeTeste: App.fundoDeTeste) }
    }

    @objc func mudaJanela(_ sender: NSSegmentedControl) {
        let i = min(max(sender.selectedSegment, 0), JANELAS.count - 1)
        App.comum.com { $0.m.janela = i }
        needsDisplay = true
    }

    // com o menu aberto a barra acompanha cada amostra, igual ao painel
    func menuWillOpen(_ menu: NSMenu) {
        App.comum.com { c in
            c.menuAberto = true
            // config.toml editado: cores novas ja neste menu e na barra
            if c.m.recarregaConfig() { c.barra.classe = .max }
            _ = barraMudou(c, aberto: true)
            App.aplicaBarra(c.barra, c.m.faixas)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        App.comum.com { $0.menuAberto = false }
        App.menuFechou()
    }
}
