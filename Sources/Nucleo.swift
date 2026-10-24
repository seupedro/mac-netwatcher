// Nucleo do Mac Netwatcher: config, faixas de cor, historico, quedas e analise.
// Arquivos em ~/.netwatch: samples.csv (uma linha por teste), events.log
// (quedas, voltas, pausas) e config.toml (faixas de cor e idioma).

import Darwin

let DIA: Double = 86_400
let JANELAS: [(seg: Double, nome: String)] = [
    (60, "1m"), (300, "5m"), (900, "15m"), (3600, "1h"), (21_600, "6h"), (DIA, "24h"),
]
let ALVOS_PADRAO = ["1.1.1.1:443", "8.8.8.8:443", "9.9.9.9:443"]
/// So le o fim do samples.csv: 24h a cada 2 s cabem folgados em 6 MB.
let CAUDA_CSV = 6 << 20
/// O samples.csv vai para o disco em lotes: uma escrita a cada 30 s em vez de
/// uma por amostra. Quedas e voltas gravam na hora.
let LOTE_CSV: Double = 30
let ESCALAS: [Float] = [50, 100, 150, 200, 300, 400, 500, 750, 1000, 1500, 2000, 3000, 5000]

struct Amostra {
    /// epoch em segundos
    var t: Double
    /// nil = todos os alvos sem resposta
    var ms: Float?
}

// ---------------------------------------------------------------- tempo e texto

func agora() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_REALTIME, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
}

/// Relogio que nao anda com o Mac dormindo nem quando o usuario acerta a hora.
func monotonico() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
}

func horaLocal(_ t: Double) -> tm {
    var s = time_t(t.rounded(.down))
    var r = tm()
    localtime_r(&s, &r)
    return r
}

/// strftime na hora local. Sem DateFormatter: ele carrega ICU e calendarios.
func fmt(_ t: Double, _ formato: String) -> String {
    var r = horaLocal(t)
    var buf = [CChar](repeating: 0, count: 64)
    let n = strftime(&buf, buf.count, formato, &r)
    return String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// 2026-10-23T18:37:00-03:00.
func rfc3339(_ t: Double) -> String {
    let off = horaLocal(t).tm_gmtoff
    let sinal = off < 0 ? "-" : "+"
    let a = abs(off) / 60
    return fmt(t, "%Y-%m-%dT%H:%M:%S") + sinal + dois(Int(a / 60)) + ":" + dois(Int(a % 60))
}

func dois(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

func dur(_ seg: Double) -> String {
    let s = Int(max(seg, 0))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m\(dois(s % 60))s" }
    return "\(s / 3600)h\(dois((s % 3600) / 60))m"
}

/// Numero sem ".0" quando e inteiro: 2 e 150.5.
func numTexto(_ v: Double) -> String {
    v == v.rounded() && abs(v) < 1e15 ? String(Int64(v)) : String(v)
}

func numTexto(_ v: Float) -> String {
    v == v.rounded() && abs(v) < 1e9 ? String(Int64(v)) : String(v)
}

/// Uma casa decimal ("%.1f"), sem passar por String(format:).
func umaCasa(_ v: Float) -> String {
    // empate vai para o par
    let d = Int64((Double(v) * 10).rounded(.toNearestOrEven))
    let neg = d < 0 ? "-" : ""
    return "\(neg)\(abs(d) / 10).\(abs(d) % 10)"
}

/// Percentil de uma lista ja ordenada.
func pct(_ ordenado: [Float], _ p: Double) -> Float {
    if ordenado.isEmpty { return 0 }
    let i = Int(Double(ordenado.count) * p / 100)
    return ordenado[min(i, ordenado.count - 1)]
}

/// "1 queda", "3 quedas".
func nQuedas(_ n: Int) -> String {
    n == 1 ? tr("1 queda", "1 outage") : tr("\(n) quedas", "\(n) outages")
}

// ---------------------------------------------------------------- arquivos

func juntar(_ dir: String, _ nome: String) -> String {
    dir.hasSuffix("/") ? dir + nome : dir + "/" + nome
}

func existe(_ caminho: String) -> Bool { access(caminho, F_OK) == 0 }

func criaPastas(_ caminho: String) {
    var atual = ""
    for parte in caminho.split(separator: "/", omittingEmptySubsequences: true) {
        atual += "/" + parte
        mkdir(atual, 0o755)
    }
}

func gravaTudo(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var feito = 0
    while feito < bytes.count {
        let n = bytes[feito...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n < 0 {
            if errno == EINTR { continue }
            return false
        }
        feito += n
    }
    return true
}

/// Troca o arquivo inteiro de uma vez (temporario + rename).
func escreveArquivo(_ caminho: String, _ texto: String) -> String? {
    let tmp = caminho + ".tmp"
    let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if fd < 0 { return String(cString: strerror(errno)) }
    let ok = gravaTudo(fd, Array(texto.utf8))
    close(fd)
    if !ok || rename(tmp, caminho) != 0 { return String(cString: strerror(errno)) }
    return nil
}

func leArquivo(_ caminho: String) -> String? {
    let fd = open(caminho, O_RDONLY)
    if fd < 0 { return nil }
    defer { close(fd) }
    var tudo: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 16 << 10)
    while true {
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { break }
        tudo += buf[0..<n]
    }
    return String(decoding: tudo, as: UTF8.self)
}

func dataModificacao(_ caminho: String) -> timespec? {
    var st = stat()
    return stat(caminho, &st) == 0 ? st.st_mtimespec : nil
}

func evento(_ dir: String, _ tipo: String, _ texto: String) {
    eventoEm(dir, agora(), tipo, texto)
}

/// CAIU e VOLTOU levam a hora da amostra, nao a de quando a sonda terminou
/// (com timeout e alvos de reserva, ela pode levar varios segundos).
func eventoEm(_ dir: String, _ t: Double, _ tipo: String, _ texto: String) {
    let fd = open(juntar(dir, "events.log"), O_WRONLY | O_APPEND | O_CREAT, 0o644)
    if fd < 0 { return }
    _ = gravaTudo(fd, Array("\(rfc3339(t))\t\(tipo)\t\(texto)\n".utf8))
    close(fd)
}

// ---------------------------------------------------------------- config

struct Config {
    var intervalo: Double = 2
    var timeout: Double = 3
    var alvos: [Endereco] = []
    var alvosTxt: [String] = []
    var dir: String

    /// Intervalo 2 s, timeout 3 s, os tres alvos de sempre, logs em
    /// ~/.netwatch (ou $NETWATCH_DIR). Os alvos ainda precisam de resolveAlvos.
    static func padrao() -> Config? {
        if let d = getenv("NETWATCH_DIR") { return Config(dir: String(cString: d)) }
        guard let h = getenv("HOME") else { return nil }
        return Config(dir: juntar(String(cString: h), ".netwatch"))
    }

    mutating func resolveAlvos() -> String? {
        if alvosTxt.isEmpty { alvosTxt = ALVOS_PADRAO }
        alvos = []
        for i in alvosTxt.indices {
            if !alvosTxt[i].contains(":") { alvosTxt[i] += ":443" }
            guard let e = Endereco(alvosTxt[i]) else { return "alvo invalido: \(alvosTxt[i])" }
            alvos.append(e)
        }
        return nil
    }
}

struct RGB: Equatable {
    var r: UInt8, g: UInt8, b: UInt8
    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { (self.r, self.g, self.b) = (r, g, b) }

    var hex: String {
        let h = { (v: UInt8) -> String in
            let s = String(v, radix: 16)
            return s.count == 1 ? "0" + s : s
        }
        return "#" + h(r) + h(g) + h(b)
    }

    static func de(_ s: String) -> RGB? {
        let h = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard h.utf8.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return RGB(UInt8(v >> 16), UInt8((v >> 8) & 0xff), UInt8(v & 0xff))
    }
}

/// Uma faixa de cor da latencia; ateMs nil = sem limite de cima.
struct Faixa: Equatable {
    var ateMs: Float?
    var cor: RGB
    var corEscuro: RGB
}

struct Faixas: Equatable {
    var lista: [Faixa]

    /// Verde ate 100 ms, amarelo ate 200, laranja ate 300, vermelho acima.
    static let padrao = Faixas(lista: [
        Faixa(ateMs: 100, cor: RGB(0x16, 0x80, 0x38), corEscuro: RGB(0x30, 0xd1, 0x58)),
        Faixa(ateMs: 200, cor: RGB(0x96, 0x73, 0x00), corEscuro: RGB(0xff, 0xd6, 0x0a)),
        Faixa(ateMs: 300, cor: RGB(0xd2, 0x5a, 0x00), corEscuro: RGB(0xff, 0x9f, 0x0a)),
        Faixa(ateMs: nil, cor: RGB(0xc8, 0x24, 0x24), corEscuro: RGB(0xff, 0x69, 0x61)),
    ])

    /// Indice da faixa de `ms`.
    func indice(_ ms: Float) -> Int {
        lista.firstIndex { f in f.ateMs.map { ms <= $0 } ?? true } ?? lista.count - 1
    }

    func cor(_ ms: Float, escuro: Bool) -> RGB { corDe(indice(ms), escuro: escuro) }

    func corDe(_ i: Int, escuro: Bool) -> RGB {
        let f = lista[min(i, lista.count - 1)]
        return escuro ? f.corEscuro : f.cor
    }
}

/// Comentario no topo do config.toml, no idioma em uso.
func cabecalhoConfig() -> String {
    tr("""
        # Configuracao do Mac Netwatcher. Da para editar aqui ou em
        # Configuracoes..., no menu do app. Depois de salvar o arquivo, abra o
        # menu de novo para aplicar.

        # Idioma: "pt" ou "en". Sem esta linha, segue o idioma do macOS.

        """, """
        # Mac Netwatcher settings. Edit them here or in Settings..., in the app
        # menu. After saving this file, open the menu again to apply.

        # Language: "pt" or "en". Without this line, it follows macOS.

        """)
}

func cabecalhoFaixas() -> String {
    tr("""

        # Faixas de cor da latencia, da menor para a maior. Cada faixa vale ate
        # `ate_ms` (inclusive); a ultima, sem `ate_ms`, vale para o resto.
        # `cor` e usada no tema claro e `cor_escuro` no tema escuro (opcional: sem
        # ela, `cor` vale nos dois). Pode ter quantas faixas quiser.

        """, """

        # Latency color bands, from lowest to highest. Each band applies up to
        # `ate_ms` (inclusive); the last one, without `ate_ms`, covers the rest.
        # `cor` is used in light mode and `cor_escuro` in dark mode (optional:
        # without it, `cor` is used in both). Add as many bands as you like.

        """)
}

/// O que o config.toml guarda. idioma nil = o do sistema.
struct ConfigArquivo: Equatable {
    var faixas: Faixas = .padrao
    var idioma: Idioma?
}

/// Texto completo de um config.toml com estas faixas e este idioma.
func textoConfig(_ f: Faixas, idioma: Idioma? = nil) -> String {
    var s = cabecalhoConfig()
    if let idioma { s += "idioma = \"\(idioma.rawValue)\"\n" }
    s += cabecalhoFaixas() + "faixas = [\n"
    for x in f.lista {
        let limite = x.ateMs.map { "ate_ms = \(numTexto($0)), " } ?? ""
        let escuro = x.corEscuro == x.cor ? "" : ", cor_escuro = \"\(x.corEscuro.hex)\""
        s += "  { \(limite)cor = \"\(x.cor.hex)\"\(escuro) },\n"
    }
    return s + "]\n"
}

/// Troca so a linha `idioma = ...` de um config.toml (nil = tira a linha),
/// sem mexer no resto do texto.
func trocaIdioma(_ texto: String, _ idioma: Idioma?) -> String {
    var linhas = texto.split(separator: "\n", omittingEmptySubsequences: false).filter { l in
        let t = l.drop { $0 == " " || $0 == "\t" }
        guard t.hasPrefix("idioma") else { return true }
        let resto = t.dropFirst("idioma".count).drop { $0 == " " || $0 == "\t" }
        return !resto.hasPrefix("=")
    }
    if let idioma { linhas.insert(Substring("idioma = \"\(idioma.rawValue)\""), at: 0) }
    return linhas.joined(separator: "\n")
}

/// Resultado com a mensagem de erro em texto (Result exige um tipo Error).
enum Lido<T> {
    case success(T)
    case failure(String)
}

/// Le e valida o texto de um config.toml. Com erro nas faixas, o idioma
/// ainda vale (se a linha dele estiver certa): um erro de digitacao nas
/// cores nao troca o idioma do app.
func lerConfig(_ texto: String) -> (ConfigArquivo, String?) {
    let raiz: [(String, NoToml)]
    do {
        var leitor = LeitorToml(texto)
        raiz = try leitor.documento()
    } catch let e as ErroToml {
        return (ConfigArquivo(), e.msg)
    } catch {
        return (ConfigArquivo(), "\(error)")
    }
    var r = ConfigArquivo()
    var faixas: NoToml?
    var erroIdioma: String?
    for (k, v) in raiz {
        switch (k, v.v) {
        case ("faixas", _):
            faixas = v
        case ("idioma", .texto(let s)):
            if let i = Idioma(rawValue: s) {
                r.idioma = i
            } else {
                erroIdioma = tr("linha \(v.linha): idioma \"\(s)\" nao existe (use \"pt\" ou \"en\")",
                                "line \(v.linha): unknown language \"\(s)\" (use \"pt\" or \"en\")")
            }
        case ("idioma", _):
            erroIdioma = tr("linha \(v.linha): `idioma` tem que ser um texto (\"pt\" ou \"en\")",
                            "line \(v.linha): `idioma` must be a string (\"pt\" or \"en\")")
        default:
            return (r, tr("linha \(v.linha): campo desconhecido `\(k)` (os campos sao `idioma` e `faixas`)",
                          "line \(v.linha): unknown field `\(k)` (the fields are `idioma` and `faixas`)"))
        }
    }
    guard let faixas else { return (r, tr("falta o campo `faixas`", "missing field `faixas`")) }
    switch lerFaixas(faixas) {
    case .success(let f): r.faixas = f
    case .failure(let e): return (r, e)
    }
    return (r, erroIdioma)
}

/// Le e valida so as faixas de um config.toml.
func lerFaixas(_ texto: String) -> Lido<Faixas> {
    let (c, e) = lerConfig(texto)
    if let e { return .failure(e) }
    return .success(c.faixas)
}

private func lerFaixas(_ faixas: NoToml) -> Lido<Faixas> {
    guard case .lista(let itens) = faixas.v else {
        return .failure(tr("linha \(faixas.linha): `faixas` tem que ser uma lista",
                           "line \(faixas.linha): `faixas` must be a list"))
    }
    if itens.isEmpty { return .failure(tr("faixas vazia: precisa de pelo menos uma", "`faixas` is empty: it needs at least one band")) }
    var v: [Faixa] = []
    for (i, item) in itens.enumerated() {
        let n = i + 1
        guard case .tabela(let campos) = item.v else {
            return .failure(tr("linha \(item.linha): cada faixa tem que ser uma tabela { ... }",
                               "line \(item.linha): each band must be a table { ... }"))
        }
        var ate: Float?
        var cor: String?
        var corEscuro: String?
        for (k, c) in campos {
            switch (k, c.v) {
            case ("ate_ms", .numero(let x)): ate = Float(x)
            case ("cor", .texto(let s)): cor = s
            case ("cor_escuro", .texto(let s)): corEscuro = s
            case ("ate_ms", _):
                return .failure(tr("linha \(c.linha): `ate_ms` tem que ser um numero", "line \(c.linha): `ate_ms` must be a number"))
            case ("cor", _), ("cor_escuro", _):
                return .failure(tr("linha \(c.linha): `\(k)` tem que ser um texto \"#rrggbb\"",
                                   "line \(c.linha): `\(k)` must be a string \"#rrggbb\""))
            default:
                return .failure(tr("linha \(c.linha): campo desconhecido `\(k)` (os campos sao ate_ms, cor e cor_escuro)",
                                   "line \(c.linha): unknown field `\(k)` (the fields are ate_ms, cor and cor_escuro)"))
            }
        }
        guard let cor else {
            return .failure(tr("linha \(item.linha): falta o campo `cor`", "line \(item.linha): missing field `cor`"))
        }
        let invalida = { (c: String) in
            tr("faixa \(n): cor invalida \"\(c)\" (use #rrggbb)", "band \(n): invalid color \"\(c)\" (use #rrggbb)")
        }
        guard let rgb = RGB.de(cor) else { return .failure(invalida(cor)) }
        var rgbEscuro = rgb
        if let c = corEscuro {
            guard let e = RGB.de(c) else { return .failure(invalida(c)) }
            rgbEscuro = e
        }
        let ultima = n == itens.count
        if ate == nil && !ultima {
            return .failure(tr("faixa \(n): falta ate_ms (so a ultima pode ficar sem)",
                               "band \(n): missing ate_ms (only the last one can go without)"))
        }
        if let l = ate, let ant = v.last?.ateMs, l <= ant {
            return .failure(tr("faixa \(n): ate_ms = \(numTexto(l)) tem que ser maior que o da anterior (\(numTexto(ant)))",
                               "band \(n): ate_ms = \(numTexto(l)) must be greater than the previous one (\(numTexto(ant)))"))
        }
        v.append(Faixa(ateMs: ate, cor: rgb, corEscuro: rgbEscuro))
    }
    return .success(Faixas(lista: v))
}

/// Le o config.toml da pasta dos logs, criando com o padrao se nao existir.
/// Com erro, devolve as faixas padrao (e o idioma, se deu para ler) e a
/// mensagem.
func carregarConfig(_ dir: String) -> (ConfigArquivo, String?) {
    let caminho = juntar(dir, "config.toml")
    if !existe(caminho) { _ = escreveArquivo(caminho, textoConfig(.padrao)) }
    guard let texto = leArquivo(caminho) else {
        return (ConfigArquivo(), tr("config.toml: nao deu para ler", "config.toml: couldn't read it"))
    }
    let (c, e) = lerConfig(texto)
    guard let e else { return (c, nil) }
    return (ConfigArquivo(faixas: .padrao, idioma: c.idioma), "config.toml: \(e)")
}

// ---------------------------------------------------------------- toml

/// So o pedaco de TOML que o config usa: chaves, textos, numeros, booleanos,
/// listas, tabelas em linha e cabecalhos [x] / [[x]].
indirect enum Toml {
    case texto(String)
    case numero(Double)
    case logico(Bool)
    case lista([NoToml])
    case tabela([(String, NoToml)])
}

struct NoToml {
    var v: Toml
    var linha: Int
}

struct ErroToml: Error { var msg: String }

struct LeitorToml {
    private let b: [UInt8]
    private var i = 0
    private var linha = 1

    init(_ texto: String) { b = Array(texto.utf8) }

    private var fim: Bool { i >= b.count }
    private var atual: UInt8 { i < b.count ? b[i] : 0 }

    private func erro(_ msg: String) -> ErroToml { ErroToml(msg: tr("linha", "line") + " \(linha): \(msg)") }

    private mutating func anda() {
        if atual == UInt8(ascii: "\n") { linha += 1 }
        i += 1
    }

    private mutating func pulaEspacos() {
        while atual == UInt8(ascii: " ") || atual == UInt8(ascii: "\t") { anda() }
    }

    /// Espacos, quebras de linha e comentarios.
    private mutating func pulaBrancos() {
        while !fim {
            switch atual {
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"), UInt8(ascii: "\n"): anda()
            case UInt8(ascii: "#"): while !fim && atual != UInt8(ascii: "\n") { anda() }
            default: return
            }
        }
    }

    /// Depois de um valor so pode vir comentario e fim de linha.
    private mutating func fimDeLinha() throws {
        pulaEspacos()
        if atual == UInt8(ascii: "#") { while !fim && atual != UInt8(ascii: "\n") { anda() } }
        if atual == UInt8(ascii: "\r") { anda() }
        if !fim && atual != UInt8(ascii: "\n") { throw erro(tr("esperava fim de linha depois do valor", "expected end of line after the value")) }
    }

    private mutating func espera(_ c: Character) throws {
        guard atual == c.asciiValue! else { throw erro(tr("esperava `\(c)`", "expected `\(c)`")) }
        anda()
    }

    private mutating func chave() throws -> String {
        if atual == UInt8(ascii: "\"") || atual == UInt8(ascii: "'") { return try texto() }
        let ini = i
        while !fim, let c = Optional(atual),
              (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a)
                || c == UInt8(ascii: "_") || c == UInt8(ascii: "-") {
            anda()
        }
        if i == ini { throw erro(tr("esperava um nome de campo", "expected a field name")) }
        let k = String(decoding: b[ini..<i], as: UTF8.self)
        pulaEspacos()
        if atual == UInt8(ascii: ".") { throw erro(tr("chave com ponto (`\(k).…`) nao e suportada", "dotted keys (`\(k).…`) are not supported")) }
        return k
    }

    mutating func documento() throws -> [(String, NoToml)] {
        var raiz: [(String, NoToml)] = []
        // cabecalho atual: [x] ou [[x]] (indice do item na lista)
        var destino: (chave: String, item: Int?)?
        func poe(_ k: String, _ v: NoToml, em lista: inout [(String, NoToml)], _ leitor: LeitorToml) throws {
            if lista.contains(where: { $0.0 == k }) { throw leitor.erro(tr("campo `\(k)` repetido", "duplicate field `\(k)`")) }
            lista.append((k, v))
        }
        while true {
            pulaBrancos()
            if fim { break }
            if atual == UInt8(ascii: "[") {
                let l = linha
                anda()
                let duplo = atual == UInt8(ascii: "[")
                if duplo { anda() }
                pulaEspacos()
                let k = try chave()
                pulaEspacos()
                try espera("]")
                if duplo { try espera("]") }
                try fimDeLinha()
                let pos = raiz.firstIndex { $0.0 == k }
                if duplo {
                    let nova = NoToml(v: .tabela([]), linha: l)
                    if let p = pos {
                        guard case .lista(var itens) = raiz[p].1.v else { throw erro(tr("campo `\(k)` repetido", "duplicate field `\(k)`")) }
                        itens.append(nova)
                        raiz[p].1.v = .lista(itens)
                        destino = (k, itens.count - 1)
                    } else {
                        raiz.append((k, NoToml(v: .lista([nova]), linha: l)))
                        destino = (k, 0)
                    }
                } else {
                    if pos != nil { throw erro(tr("campo `\(k)` repetido", "duplicate field `\(k)`")) }
                    raiz.append((k, NoToml(v: .tabela([]), linha: l)))
                    destino = (k, nil)
                }
                continue
            }
            let k = try chave()
            pulaEspacos()
            try espera("=")
            pulaEspacos()
            let v = try valor()
            try fimDeLinha()
            guard let d = destino, let p = raiz.firstIndex(where: { $0.0 == d.chave }) else {
                try poe(k, v, em: &raiz, self)
                continue
            }
            // campo dentro da tabela do cabecalho atual
            if let item = d.item {
                guard case .lista(var itens) = raiz[p].1.v, case .tabela(var campos) = itens[item].v else { continue }
                try poe(k, v, em: &campos, self)
                itens[item].v = .tabela(campos)
                raiz[p].1.v = .lista(itens)
            } else if case .tabela(var campos) = raiz[p].1.v {
                try poe(k, v, em: &campos, self)
                raiz[p].1.v = .tabela(campos)
            }
        }
        return raiz
    }

    private mutating func valor() throws -> NoToml {
        let l = linha
        switch atual {
        case UInt8(ascii: "\""), UInt8(ascii: "'"):
            return NoToml(v: .texto(try texto()), linha: l)
        case UInt8(ascii: "["):
            anda()
            var itens: [NoToml] = []
            while true {
                pulaBrancos()
                if atual == UInt8(ascii: "]") { anda(); break }
                itens.append(try valor())
                pulaBrancos()
                if atual == UInt8(ascii: ",") { anda(); continue }
                pulaBrancos()
                try espera("]")
                break
            }
            return NoToml(v: .lista(itens), linha: l)
        case UInt8(ascii: "{"):
            anda()
            var campos: [(String, NoToml)] = []
            while true {
                pulaBrancos()
                if atual == UInt8(ascii: "}") { anda(); break }
                let lk = linha
                let k = try chave()
                pulaEspacos()
                try espera("=")
                pulaEspacos()
                var v = try valor()
                v.linha = lk
                if campos.contains(where: { $0.0 == k }) { throw erro(tr("campo `\(k)` repetido", "duplicate field `\(k)`")) }
                campos.append((k, v))
                pulaBrancos()
                if atual == UInt8(ascii: ",") { anda(); continue }
                pulaBrancos()
                try espera("}")
                break
            }
            return NoToml(v: .tabela(campos), linha: l)
        default:
            let ini = i
            while !fim, ![UInt8(ascii: ","), UInt8(ascii: "]"), UInt8(ascii: "}"), UInt8(ascii: " "),
                          UInt8(ascii: "\t"), UInt8(ascii: "\r"), UInt8(ascii: "\n"), UInt8(ascii: "#")].contains(atual) {
                anda()
            }
            let s = String(decoding: b[ini..<i], as: UTF8.self)
            if s == "true" { return NoToml(v: .logico(true), linha: l) }
            if s == "false" { return NoToml(v: .logico(false), linha: l) }
            let limpo = s.replacingAll("_", "")
            guard !limpo.isEmpty, let d = Double(limpo), d.isFinite else {
                throw ErroToml(msg: tr("linha \(l): valor invalido `\(s)`", "line \(l): invalid value `\(s)`"))
            }
            return NoToml(v: .numero(d), linha: l)
        }
    }

    private mutating func texto() throws -> String {
        let aspas = atual
        anda()
        var bytes: [UInt8] = []
        while true {
            if fim || atual == UInt8(ascii: "\n") { throw erro(tr("texto sem fechar as aspas", "unterminated string")) }
            let c = atual
            anda()
            if c == aspas { break }
            if c == UInt8(ascii: "\\") && aspas == UInt8(ascii: "\"") {
                let e = atual
                anda()
                switch e {
                case UInt8(ascii: "n"): bytes.append(0x0a)
                case UInt8(ascii: "t"): bytes.append(0x09)
                case UInt8(ascii: "r"): bytes.append(0x0d)
                case UInt8(ascii: "\""), UInt8(ascii: "\\"): bytes.append(e)
                case UInt8(ascii: "u"), UInt8(ascii: "U"):
                    let n = e == UInt8(ascii: "u") ? 4 : 8
                    guard i + n <= b.count, let v = UInt32(String(decoding: b[i..<i + n], as: UTF8.self), radix: 16),
                          let u = Unicode.Scalar(v) else { throw erro(tr("escape \\u invalido", "invalid \\u escape")) }
                    i += n
                    bytes += Array(String(Character(u)).utf8)
                default: throw erro(tr("escape invalido", "invalid escape"))
                }
                continue
            }
            bytes.append(c)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension String {
    func replacingAll(_ de: Character, _ por: String) -> String {
        var s = ""
        for c in self { if c == de { s += por } else { s.append(c) } }
        return s
    }
}

// ---------------------------------------------------------------- historico

/// Amostras das ultimas 24h em 8 bytes cada: o tempo vai em
/// decimos de segundo desde `base` e a latencia em Float, com NaN para falha.
/// As antigas saem pelo comeco sem mover o resto (o espaco e recuperado aos
/// poucos, quando a parte descartada passa da metade).
struct Historico {
    private(set) var base: Double = 0
    private var ds: [Int32] = []
    private var lat: [Float] = []
    private var ini = 0

    var count: Int { ds.count - ini }
    var isEmpty: Bool { count == 0 }

    subscript(k: Int) -> Amostra {
        let j = ini + k
        let v = lat[j]
        return Amostra(t: base + Double(ds[j]) / 10, ms: v.isNaN ? nil : v)
    }

    func t(_ k: Int) -> Double { base + Double(ds[ini + k]) / 10 }
    func ms(_ k: Int) -> Float? {
        let v = lat[ini + k]
        return v.isNaN ? nil : v
    }

    mutating func reserva(_ n: Int) {
        ds.reserveCapacity(n)
        lat.reserveCapacity(n)
    }

    mutating func append(_ a: Amostra) {
        if ds.isEmpty { base = a.t.rounded(.down) }
        ds.append(Int32(((a.t - base) * 10).rounded()))
        lat.append(a.ms ?? .nan)
    }

    /// Tira do comeco as amostras com t < limite.
    mutating func descartaAte(_ limite: Double) {
        while ini < ds.count && base + Double(ds[ini]) / 10 < limite { ini += 1 }
        if ini > 1024 && ini * 2 > ds.count {
            ds.removeFirst(ini)
            lat.removeFirst(ini)
            ini = 0
        }
    }

    /// Poe em ordem de tempo (so quando o samples.csv veio fora de ordem).
    mutating func ordena() {
        let todas = (0..<count).map { self[$0] }.sorted { $0.t < $1.t }
        let capacidade = ds.capacity
        self = Historico()
        reserva(capacidade)
        for a in todas { append(a) }
    }

    /// Indice da primeira amostra com t >= t0 (busca binaria).
    func desde(_ t0: Double) -> Int {
        var (lo, hi) = (0, count)
        while lo < hi {
            let m = (lo + hi) / 2
            if t(m) < t0 { lo = m + 1 } else { hi = m }
        }
        return lo
    }
}

/// Le o fim do samples.csv aos pedacos de 64 KB (sem carregar os 6 MB de uma
/// vez) e poe as amostras desde `desde` direto no historico, em ordem. Sem
/// lista intermediaria: com 24h no arquivo ela ocupava 690 KB que o malloc
/// nao devolvia depois.
func carregar(_ caminho: String, desde: Double, em h: inout Historico) {
    let fd = open(caminho, O_RDONLY)
    if fd < 0 { return }
    defer { close(fd) }
    var st = stat()
    fstat(fd, &st)
    let cortou = Int(st.st_size) > CAUDA_CSV
    if cortou { lseek(fd, off_t(Int(st.st_size) - CAUDA_CSV), SEEK_SET) }
    var pular = cortou  // primeira linha veio cortada pelo seek
    var resto: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 64 << 10)
    var ultimo = -Double.infinity
    var ordenado = true
    func linha(_ l: ArraySlice<UInt8>) {
        // horario,epoch,ms,alvo: so interessam o 2o e o 3o campo
        var virgulas = 0
        var ini1 = l.endIndex, ini2 = l.endIndex, fim2 = l.endIndex
        for j in l.indices where l[j] == UInt8(ascii: ",") {
            virgulas += 1
            if virgulas == 1 { ini1 = j + 1 } else if virgulas == 2 { ini2 = j + 1 } else { fim2 = j; break }
        }
        guard virgulas >= 2, let t = decimal(l[ini1..<(ini2 - 1)]) else { return } // cabecalho cai aqui
        if t < desde { return }
        if t < ultimo { ordenado = false }
        ultimo = t
        h.append(Amostra(t: t, ms: decimal(l[ini2..<fim2]).map { Float($0) }))
    }
    while true {
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { break }
        var a = 0
        for j in 0..<n where buf[j] == UInt8(ascii: "\n") {
            if resto.isEmpty {
                if !pular { linha(buf[a..<j]) }
            } else {
                resto += buf[a..<j]
                if !pular { linha(resto[...]) }
                resto.removeAll(keepingCapacity: true)
            }
            pular = false
            a = j + 1
        }
        resto += buf[a..<n]
    }
    if !resto.isEmpty && !pular { linha(resto[...]) }
    // duas instancias gravando juntas podem intercalar fora de ordem
    if !ordenado { h.ordena() }
}

/// Numero decimal simples ("1792791420", "14.2", "-3"); nil se vazio ou lixo.
func decimal(_ s: ArraySlice<UInt8>) -> Double? {
    var j = s.startIndex
    var neg = false
    if j < s.endIndex && s[j] == UInt8(ascii: "-") { neg = true; j += 1 }
    var inteiro: Double = 0, frac: Double = 0, escala: Double = 1
    var digitos = 0, ponto = false
    while j < s.endIndex {
        let c = s[j]
        if c >= 0x30 && c <= 0x39 {
            if ponto { escala /= 10; frac += Double(c - 0x30) * escala } else { inteiro = inteiro * 10 + Double(c - 0x30) }
            digitos += 1
        } else if c == UInt8(ascii: ".") && !ponto {
            ponto = true
        } else if c == UInt8(ascii: "\r") && j == s.endIndex - 1 {
            break
        } else {
            return nil
        }
        j += 1
    }
    if digitos == 0 { return nil }
    let v = inteiro + frac
    return neg ? -v : v
}

/// Estado de uma sessao de monitoramento: historico das ultimas 24h e
/// contadores da sessao. Grava samples.csv e events.log.
final class Monitor {
    var cfg: Config
    /// ultimas 24h, incluindo o que ja estava no samples.csv
    var hist = Historico()
    var medindo = true
    var online = true
    var caiuEm: Double = 0
    var quedas = 0
    var fora: Double = 0
    let inicio: Double
    /// ultima latencia e o indice do alvo que respondeu
    var ultimo: (ms: Float, alvo: Int)?
    /// indice em JANELAS escolhido no painel
    var janela = 1
    /// faixas de cor do config.toml (ou as padrao, se ele tiver erro)
    var faixas: Faixas = .padrao
    /// idioma escolhido no config.toml; nil = o do sistema
    var idioma: Idioma?
    var erroConfig: String?
    private var configLidoEm: timespec?
    private let csv: Int32
    private var buffer: [UInt8] = []
    private var gravouEm: Double
    private var ultimoT: Double?

    init?(_ cfg: Config) {
        criaPastas(cfg.dir)
        let caminho = juntar(cfg.dir, "samples.csv")
        let novo = !existe(caminho)
        csv = open(caminho, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        if csv < 0 { return nil }
        if novo { _ = gravaTudo(csv, Array("horario,epoch,ms,alvo\n".utf8)) }
        self.cfg = cfg
        inicio = agora()
        gravouEm = inicio
        leConfig()  // antes do INICIO: o events.log sai no idioma escolhido
        let alvos = cfg.alvosTxt.joined(separator: " ")
        evento(cfg.dir, tr("INICIO", "START"), tr("intervalo \(numTexto(cfg.intervalo))s, alvos \(alvos)",
                                                  "interval \(numTexto(cfg.intervalo))s, targets \(alvos)"))
        hist.reserva(Int(DIA / cfg.intervalo) + 64)
        carregar(caminho, desde: inicio - DIA, em: &hist)
        buffer.reserveCapacity(4096)
        // devolve ao sistema o que a leitura usou de passagem
        malloc_zone_pressure_relief(nil, 0)
    }

    func registra(_ a: Amostra, alvo: Int?) {
        let lim = cfg.intervalo * 3 + cfg.timeout * 2
        // A maquina dormiu? O relogio pula sem que a sonda tenha rodado.
        if let u = ultimoT, a.t - u > lim {
            // uma queda aberta antes da pausa termina na ultima medicao, sem
            // engolir o tempo dormindo
            if !online {
                let fim = u + cfg.intervalo
                fora += fim - caiuEm
                online = true
                eventoEm(cfg.dir, fim, tr("VOLTOU", "UP"),
                         tr("ficou fora \(dur(fim - caiuEm)) (sem confirmacao: a medicao parou)",
                            "was down \(dur(fim - caiuEm)) (unconfirmed: measuring stopped)"))
            }
            evento(cfg.dir, tr("PAUSA", "PAUSE"), tr("sem medicao por \(dur(a.t - u)) (mac dormiu ou app parado)",
                                                     "no measurements for \(dur(a.t - u)) (Mac asleep or app stopped)"))
        }
        ultimoT = a.t
        medindo = false
        hist.append(a)
        hist.descartaAte(a.t - DIA)
        let mudou = (a.ms != nil) != online
        switch (a.ms, online) {
        case (nil, true):
            online = false
            quedas += 1
            caiuEm = a.t
            eventoEm(cfg.dir, a.t, tr("CAIU", "DOWN"), tr("todos os alvos sem resposta", "no target answered"))
        case (.some, false):
            let d = a.t - caiuEm
            fora += d
            online = true
            eventoEm(cfg.dir, a.t, tr("VOLTOU", "UP"), tr("ficou fora \(dur(d))", "was down \(dur(d))"))
        default:
            break
        }
        if let ms = a.ms, let alvo { ultimo = (ms, alvo) } else { ultimo = nil }

        let ms = a.ms.map(umaCasa) ?? ""
        let rot = alvo.map { cfg.alvos[$0].rotulo } ?? ""
        buffer += "\(rfc3339(a.t)),\(Int64(a.t.rounded(.toNearestOrEven))),\(ms),\(rot)\n".utf8
        if mudou || a.t - gravouEm >= LOTE_CSV { grava(a.t) }
    }

    private func grava(_ t: Double) {
        if !buffer.isEmpty { _ = gravaTudo(csv, buffer) }
        buffer.removeAll(keepingCapacity: true)
        gravouEm = t
    }

    /// Rele o config.toml se ele mudou desde a ultima leitura; devolve true
    /// se releu.
    func recarregaConfig() -> Bool {
        let d = dataModificacao(juntar(cfg.dir, "config.toml"))
        if d?.tv_sec == configLidoEm?.tv_sec && d?.tv_nsec == configLidoEm?.tv_nsec { return false }
        leConfig()
        return true
    }

    /// Le o config.toml de novo, mudando ou nao, e aplica o idioma. Chamar
    /// com a trava do Comum (a fila da sonda le o idioma).
    func leConfig() {
        var (c, e) = carregarConfig(cfg.dir)
        let novo = idiomaEfetivo(c.idioma)
        if novo != idiomaAtual {
            idiomaAtual = novo
            // a mensagem de erro saiu no idioma anterior
            if e != nil { (c, e) = carregarConfig(cfg.dir) }
        }
        (faixas, idioma, erroConfig) = (c.faixas, c.idioma, e)
        configLidoEm = dataModificacao(juntar(cfg.dir, "config.toml"))
    }

    /// Grava o FIM e o que ainda estiver no buffer do samples.csv.
    func encerra() {
        grava(agora())
        if !online {
            evento(cfg.dir, tr("FIM", "END"), tr("encerrado ainda fora do ar desde \(fmt(caiuEm, "%H:%M:%S"))",
                                                 "closed while still down since \(fmt(caiuEm, "%H:%M:%S"))"))
        } else {
            evento(cfg.dir, tr("FIM", "END"), tr("\(nQuedas(quedas)), \(dur(fora)) fora do ar",
                                                 "\(nQuedas(quedas)), \(dur(fora)) down"))
        }
    }

    /// Tempo fora do ar na sessao, contando a queda em curso.
    func foraSessao(_ agora: Double) -> Double { fora + (online ? 0 : agora - caiuEm) }
}

// ---------------------------------------------------------------- analise

struct Queda {
    var ini: Double
    var fim: Double
    var emCurso: Bool
}

/// Agrupa amostras sem resposta seguidas em quedas. Uma lacuna grande entre
/// amostras (mac dormindo, programa fechado) encerra a queda sem esticar ela.
func quedas(_ m: Monitor, _ agora: Double) -> [Queda] {
    let lim = m.cfg.intervalo * 3 + m.cfg.timeout * 2
    let iv = m.cfg.intervalo
    var v: [Queda] = []
    var aberta: (ini: Double, ult: Double)?
    let h = m.hist
    for k in 0..<h.count {
        let t = h.t(k)
        let falhou = h.ms(k) == nil
        switch (falhou, aberta) {
        case (true, nil):
            aberta = (t, t)
        case (true, .some(let q)) where t - q.ult > lim:
            v.append(Queda(ini: q.ini, fim: q.ult + iv, emCurso: false))
            aberta = (t, t)
        case (true, .some(let q)):
            aberta = (q.ini, t)
        case (false, .some(let q)):
            v.append(Queda(ini: q.ini, fim: t - q.ult > lim ? q.ult + iv : t, emCurso: false))
            aberta = nil
        case (false, nil):
            break
        }
    }
    if let q = aberta {
        let emCurso = agora - q.ult <= lim
        v.append(Queda(ini: q.ini, fim: emCurso ? agora : q.ult + iv, emCurso: emCurso))
    }
    return v
}

/// Numeros de uma janela de tempo.
struct Resumo {
    var amostras: Int
    var onlinePct: Double
    var quedas: Int
    var fora: Double
    /// latencias da janela, ordenadas
    var lat: [Float]
}

func resumo(_ m: Monitor, _ qs: [Queda], _ agora: Double, _ jan: Double) -> Resumo {
    let t0 = agora - jan
    let h = m.hist
    let ini = h.desde(t0)
    var lat: [Float] = []
    lat.reserveCapacity(h.count - ini)
    for k in ini..<h.count { if let ms = h.ms(k) { lat.append(ms) } }
    lat.sort()
    let amostras = h.count - ini
    let up = amostras > 0 ? 100 * Double(lat.count) / Double(amostras) : 0
    var (nq, fora) = (0, 0.0)
    for q in qs where q.fim >= t0 {
        nq += 1
        fora += min(q.fim, agora) - max(q.ini, t0)
    }
    return Resumo(amostras: amostras, onlinePct: up, quedas: nq, fora: fora, lat: lat)
}

/// Primeiro degrau redondo com folga de 15% acima de `v`.
func escalaPara(_ v: Float) -> Float {
    let alvo = v * 1.15
    return ESCALAS.first { $0 >= alvo } ?? alvo
}

/// Passo das linhas de grade: divide o topo em 3 a 5 partes redondas.
func passoGrade(_ ymax: Float) -> Float {
    let passos: [Float] = [5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2500]
    return passos.first { p in ymax / p <= 5 && (ymax / p).truncatingRemainder(dividingBy: 1) == 0 } ?? ymax / 4
}

/// Resumo de uma coluna do grafico.
struct Balde {
    var med: Float
    var min: Float
    var max: Float
    /// 1o e 3o quartis: a faixa onde fica metade das amostras
    var q1: Float
    var q3: Float
    /// houve falha ou lacuna desde a amostra boa anterior: nao liga a linha
    var quebra: Bool
}

/// Divide [t0, t0 + jan] em `n` colunas e resume as amostras de cada uma.
func baldes(_ m: Monitor, t0: Double, jan: Double, n: Int) -> [Balde?] {
    let col = { (t: Double) -> Int in Swift.min(Swift.max(Int((t - t0) / jan * Double(n)), 0), n - 1) }
    let lacuna = m.cfg.intervalo * 2 + m.cfg.timeout * 2
    var saida = [Balde?](repeating: nil, count: n)
    var vals: [Float] = []
    var atual = Int.max
    var quebra = true, quebraBalde = true
    var ultT = -Double.infinity
    func fecha(_ b: Int) {
        if b < n && !vals.isEmpty {
            vals.sort()
            let k = vals.count / 2
            // com quantidade par, media das duas do meio (pegar so a de cima
            // fazia a coluna com 2 amostras mostrar o pico inteiro)
            let med = vals.count % 2 == 0 ? (vals[k - 1] + vals[k]) / 2 : vals[k]
            saida[b] = Balde(med: med, min: vals[0], max: vals[vals.count - 1],
                             q1: pct(vals, 25), q3: pct(vals, 75), quebra: quebraBalde)
        }
        vals.removeAll(keepingCapacity: true)
    }
    let h = m.hist
    for k in h.desde(t0)..<h.count {
        let t = h.t(k)
        let b = col(t)
        if b != atual {
            fecha(atual)
            atual = b
        }
        if t - ultT > lacuna { quebra = true }
        ultT = t
        if let ms = h.ms(k) {
            if vals.isEmpty { quebraBalde = quebra }
            vals.append(ms)
            quebra = false
        } else {
            quebra = true
        }
    }
    fecha(atual)
    return saida
}

/// Uma coluna da faixa de 24h.
enum Coluna {
    case semDado
    case falhou
    /// mediana, nao o pior: um pico isolado nao pode pintar 10 min de vermelho
    case mediana(Float)
}

func colunas24h(_ m: Monitor, _ agora: Double, _ w: Int) -> [Coluna] {
    let t0 = agora - DIA
    var falhou = [Bool](repeating: false, count: w)
    var tem = [Bool](repeating: false, count: w)
    var ms = [[Float]](repeating: [], count: w)
    let h = m.hist
    for k in h.desde(t0)..<h.count {
        let c = min(Int((h.t(k) - t0) / DIA * Double(w)), w - 1)
        tem[c] = true
        if let v = h.ms(k) { ms[c].append(v) } else { falhou[c] = true }
    }
    return (0..<w).map { c in
        if falhou[c] { return .falhou }
        if !tem[c] { return .semDado }
        return .mediana(pct(ms[c].sorted(), 50))
    }
}

/// Horas cheias multiplas de `passo` nas ultimas 24h, com a fracao (0..1) da
/// posicao delas na faixa.
func marcasHora(_ agora: Double, _ passo: Int) -> [(pos: Double, txt: String)] {
    let t0 = agora - DIA
    var r = horaLocal(t0)
    r.tm_min = 0
    r.tm_sec = 0
    r.tm_isdst = -1
    var t = Double(mktime(&r))
    var v: [(Double, String)] = []
    while t <= agora {
        let h = Int(horaLocal(t).tm_hour)
        if t >= t0 && h % passo == 0 { v.append(((t - t0) / DIA, tr("\(h)h", "\(h):00"))) }
        t += 3600
    }
    return v
}

// ---------------------------------------------------------------- janela de config

/// Uma linha da janela de configuracoes como esta na tela; ms nil = a ultima
/// faixa ("acima").
struct Rascunho {
    var ms: String?
    var claro: RGB
    var escuro: RGB
}

/// "150", "150.5" ou "150,5".
func numero(_ s: String) -> Float? {
    let limpo = s.trimmingSpaces().replacingAll(",", ".")
    guard let v = Float(limpo), v.isFinite, v > 0 else { return nil }
    return v
}

func formataMs(_ v: Float) -> String { numTexto((v * 10).rounded() / 10) }

extension String {
    func trimmingSpaces() -> String {
        var s = Substring(self)
        while let c = s.first, c.isWhitespace { s.removeFirst() }
        while let c = s.last, c.isWhitespace { s.removeLast() }
        return String(s)
    }
}

func rascunhoDe(_ f: Faixas) -> [Rascunho] {
    let n = f.lista.count
    return f.lista.enumerated().map { i, x in
        // a ultima faixa e sempre a "acima", mesmo se o arquivo der limite a ela
        Rascunho(ms: i + 1 < n ? formataMs(x.ateMs ?? 0) : nil, claro: x.cor, escuro: x.corEscuro)
    }
}

/// Confere os limites e monta as faixas. Ordena pelo limite: a cor vai junto
/// com a linha, entao digitar fora de ordem nao bagunca nada.
func valida(_ linhas: [Rascunho]) -> Lido<Faixas> {
    var comLimite: [(Float, Rascunho)] = []
    var acima: Rascunho?
    for (i, l) in linhas.enumerated() {
        if let t = l.ms {
            guard let v = numero(t) else {
                return .failure(tr("Linha \(i + 1): \"\(t)\" não é um número de ms válido.",
                                   "Row \(i + 1): \"\(t)\" is not a valid number of ms."))
            }
            comLimite.append((v, l))
        } else {
            acima = l
        }
    }
    comLimite.sort { $0.0 < $1.0 }
    for k in comLimite.indices.dropFirst() where comLimite[k].0 == comLimite[k - 1].0 {
        return .failure(tr("Duas faixas com o mesmo limite (\(formataMs(comLimite[k].0)) ms).",
                           "Two bands with the same limit (\(formataMs(comLimite[k].0)) ms)."))
    }
    guard let acima else { return .failure(tr("Falta a faixa \"acima\".", "The \"above\" band is missing.")) }
    var v = comLimite.map { Faixa(ateMs: $0.0, cor: $0.1.claro, corEscuro: $0.1.escuro) }
    v.append(Faixa(ateMs: nil, cor: acima.claro, corEscuro: acima.escuro))
    return .success(Faixas(lista: v))
}
