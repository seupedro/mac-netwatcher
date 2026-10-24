// Testes do nucleo e da sonda.
// Rodar com scripts/testar.sh.

import Darwin
import Dispatch

setvbuf(stdout, nil, _IOLBF, 0)
// as mensagens conferidas abaixo sao as em portugues, seja qual for o
// idioma do Mac (o Monitor aplica o idioma ao ler o config.toml)
setenv("NETWATCH_IDIOMA", "pt", 1)
idiomaAtual = .pt
var falhas = 0
var atual = ""

func confere(_ ok: Bool, _ msg: @autoclosure () -> String = "", linha: Int = #line) {
    if !ok {
        falhas += 1
        print("  FALHOU [\(atual)] linha \(linha): \(msg())")
    }
}

func caso(_ nome: String, _ f: () -> Void) {
    atual = nome
    let antes = falhas
    f()
    print(falhas == antes ? "ok    \(nome)" : "ERRO  \(nome)")
}

func erroDe(_ r: Lido<Faixas>) -> String {
    if case .failure(let e) = r { return e }
    return ""
}

func faixasDe(_ r: Lido<Faixas>) -> Faixas? {
    if case .success(let f) = r { return f }
    return nil
}

/// Espera ate `seg` por uma amostra entregue.
func espera(_ caixa: OSAllocatedUnfairLockCaixa, _ seg: Double) -> Amostra? {
    let fim = monotonico() + seg
    while monotonico() < fim {
        if let a = caixa.tira() { return a }
        usleep(20_000)
    }
    return nil
}

final class OSAllocatedUnfairLockCaixa: @unchecked Sendable {
    private var v: [Amostra] = []
    private var trava = pthread_mutex_t()
    init() { pthread_mutex_init(&trava, nil) }
    func poe(_ a: Amostra) { pthread_mutex_lock(&trava); v.append(a); pthread_mutex_unlock(&trava) }
    func tira() -> Amostra? {
        pthread_mutex_lock(&trava)
        defer { pthread_mutex_unlock(&trava) }
        return v.isEmpty ? nil : v.removeFirst()
    }
}

/// porta fechada no proprio Mac: o connect falha na hora
let recusa = [Endereco("127.0.0.1:9")!]

caso("pausado nao entrega e carencia segura falhas (gcd)") {
    let caixa = OSAllocatedUnfairLockCaixa()
    let s = Sonda(alvos: recusa, intervalo: 0.5, timeout: 0.2, modo: .gcd) { a, _ in caixa.poe(a) }
    s.inicia()
    s.pausa()
    _ = caixa.tira()  // pode ter saido uma antes da pausa
    usleep(100_000)
    _ = caixa.tira()
    // parado: nenhuma amostra
    confere(espera(caixa, 2) == nil, "entregou parado")
    // acordou: so falhas, ainda dentro da carencia de 20 s -> nada entregue
    s.retoma()
    confere(espera(caixa, 3) == nil, "entregou falha na carencia")
}

caso("sem pausa falha e entregue (gcd)") {
    let caixa = OSAllocatedUnfairLockCaixa()
    let s = Sonda(alvos: recusa, intervalo: 0.5, timeout: 0.2, modo: .gcd) { a, _ in caixa.poe(a) }
    s.inicia()
    let a = espera(caixa, 2)
    confere(a != nil, "deveria entregar a falha")
    confere(a?.ms == nil, "deveria ser falha")
    s.pausa()
}

caso("pausado nao entrega e carencia segura falhas (fio)") {
    let caixa = OSAllocatedUnfairLockCaixa()
    let s = Sonda(alvos: recusa, intervalo: 0.5, timeout: 0.2, modo: .fio) { a, _ in caixa.poe(a) }
    s.inicia()
    s.pausa()
    _ = caixa.tira()  // pode ter saido uma antes da pausa
    usleep(100_000)
    _ = caixa.tira()
    // parado: nenhuma amostra
    confere(espera(caixa, 2) == nil, "entregou parado")
    // acordou: so falhas, ainda dentro da carencia de 20 s -> nada entregue
    s.retoma()
    confere(espera(caixa, 3) == nil, "entregou falha na carencia")
}

caso("sem pausa falha e entregue (fio)") {
    let caixa = OSAllocatedUnfairLockCaixa()
    let s = Sonda(alvos: recusa, intervalo: 0.5, timeout: 0.2, modo: .fio) { a, _ in caixa.poe(a) }
    s.inicia()
    let a = espera(caixa, 2)
    confere(a != nil, "deveria entregar a falha")
    confere(a?.ms == nil, "deveria ser falha")
    s.pausa()
}

/// Abre um servidor TCP em 127.0.0.1 numa porta livre.
func servidor() -> (fd: Int32, porta: UInt16) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var a = sockaddr_in()
    a.sin_family = sa_family_t(AF_INET)
    a.sin_addr.s_addr = inet_addr("127.0.0.1")
    a.sin_port = 0
    var tam = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = bind(fd, $0, tam) } }
    listen(fd, 16)
    withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &tam) } }
    return (fd, UInt16(bigEndian: a.sin_port))
}

caso("testa: responde, recusa e fica com o que respondeu") {
    let (fd, porta) = servidor()
    defer { close(fd) }
    let ok = Endereco("127.0.0.1:\(porta)")!
    confere(ok.rotulo == "127.0.0.1:\(porta)" && ok.ip == "127.0.0.1", ok.rotulo)
    let r = testa([ok], [0], timeout: 1)
    confere(r != nil && r!.alvo == 0 && r!.ms < 100, "\(String(describing: r))")
    confere(testa(recusa, [0], timeout: 1) == nil, "porta fechada respondeu")
    let misto = [recusa[0], recusa[0], ok]
    let t0 = monotonico()
    let r2 = testa(misto, [0, 1, 2], timeout: 2)
    confere(r2?.alvo == 2, "\(String(describing: r2))")
    confere(monotonico() - t0 < 0.5, "esperou o timeout em vez de voltar no primeiro")
    // IP que ninguem roteia: esgota o timeout
    let t1 = monotonico()
    confere(testa([Endereco("10.255.255.1:443")!], [0], timeout: 0.3) == nil)
    confere(monotonico() - t1 < 0.6, "timeout nao respeitado")
}

caso("config padrao tem quatro faixas") {
    let f = Faixas.padrao
    confere(f.lista.count == 4)
    confere(f.indice(100) == 0)
    confere(f.indice(100.1) == 1)
    confere(f.indice(200) == 1)
    confere(f.indice(250) == 2)
    confere(f.indice(5000) == 3)
    confere(f.cor(5000, escuro: false) == RGB(0xc8, 0x24, 0x24))
    confere(f.cor(5000, escuro: true) == RGB(0xff, 0x69, 0x61))
}

caso("texto do config volta igual") {
    var f = Faixas.padrao
    confere(faixasDe(lerFaixas(textoConfig(f))) == f)
    // cor_escuro igual a cor some do arquivo e volta igual
    f.lista[0].corEscuro = f.lista[0].cor
    f.lista[1].ateMs = 150.5
    let t = textoConfig(f)
    confere(t.contains("{ ate_ms = 100, cor = \"#168038\" }"), t)
    confere(t.contains("{ ate_ms = 150.5, cor = \"#967300\", cor_escuro = \"#ffd60a\" }"), t)
    confere(faixasDe(lerFaixas(t)) == f)
}

caso("config com erro diz onde") {
    var e = erroDe(lerFaixas("faixas = [\n  { ate_ms = 100, cor = \"#00ff00\" },\n  { cor = \"vermelho\" },\n]"))
    confere(e.contains("faixa 2") && e.contains("#rrggbb"), e)
    e = erroDe(lerFaixas("faixas = [\n  { ate_ms = 200, cor = \"#00ff00\" },\n  { ate_ms = 100, cor = \"#ff0000\" },\n]"))
    confere(e.contains("maior que o da anterior"), e)
    e = erroDe(lerFaixas("faixas = [\n  { cor = \"#00ff00\" },\n  { cor = \"#ff0000\" },\n]"))
    confere(e.contains("falta ate_ms"), e)
    e = erroDe(lerFaixas("faixas = [\n  { ate_ms = 100, cor = \"#00ff00\", corr = 1 },\n]"))
    confere(e.hasPrefix("linha 2"), e)
    e = erroDe(lerFaixas("faixas = [\n  { ate_ms = 100, cor = \"#00ff00\" \n"))
    confere(e.hasPrefix("linha "), e)
    e = erroDe(lerFaixas("cores = 1\n"))
    confere(e.hasPrefix("linha 1") && e.contains("cores"), e)
    // so uma faixa, sem limite: tudo numa cor
    confere(faixasDe(lerFaixas("faixas = [{ cor = \"#123456\" }]"))?.indice(9e9) == 0)
}

caso("idioma: config.toml guarda, le e troca so a linha dele") {
    var (c, e) = lerConfig(textoConfig(.padrao, idioma: .en))
    confere(e == nil && c.idioma == .en && c.faixas == .padrao, e ?? "")
    (c, e) = lerConfig(textoConfig(.padrao))
    confere(e == nil && c.idioma == nil, e ?? "")
    (c, e) = lerConfig("idioma = \"fr\"\nfaixas = [{ cor = \"#000000\" }]\n")
    confere(c.idioma == nil && c.faixas.lista.count == 1 && (e ?? "").contains("fr"), e ?? "")
    // faixas com erro: o idioma continua valendo
    (c, e) = lerConfig("idioma = \"en\"\nfaixas = [{ cor = \"azul\" }]\n")
    confere(c.idioma == .en && e != nil)
    let t = "# x\nidioma = \"pt\"\n  idioma=\"en\"\nidiomas = 1\nfaixas = []\n"
    let en = trocaIdioma(t, .en)
    confere(en.hasPrefix("idioma = \"en\"\n# x\n") && !en.contains("\"pt\"") && en.contains("idiomas = 1"), en)
    confere(!trocaIdioma(t, nil).contains("idioma ="), trocaIdioma(t, nil))
}

caso("ingles: textos e mensagens") {
    idiomaAtual = .en
    confere(nQuedas(1) == "1 outage" && nQuedas(3) == "3 outages")
    let e = erroDe(lerFaixas("faixas = [\n  { ate_ms = 100, cor = \"#00ff00\" },\n  { cor = \"vermelho\" },\n]"))
    confere(e.contains("band 2") && e.contains("invalid color"), e)
    confere(erroDe(lerFaixas("faixas = [\n  { cor = 1 \n")).hasPrefix("line "), erroDe(lerFaixas("faixas = [\n  { cor = 1 \n")))
    confere(marcasHora(agora(), 3).allSatisfy { $0.txt.hasSuffix(":00") })
    confere(textoConfig(.padrao).contains("# Latency color bands"))
    idiomaAtual = .pt
    confere(nQuedas(1) == "1 queda" && marcasHora(agora(), 3).allSatisfy { $0.txt.hasSuffix("h") })
}

caso("toml: [[faixas]], comentarios e virgula no fim") {
    let t = """
        # comentario
        [[faixas]]
        ate_ms = 1_000 # mil
        cor = '#00ff00'

        [[faixas]]
        cor = "#ff0000"
        cor_escuro = "#FF0000"
        """
    let f = faixasDe(lerFaixas(t))
    confere(f?.lista.count == 2 && f?.lista[0].ateMs == 1000 && f?.lista[1].cor == RGB(255, 0, 0), erroDe(lerFaixas(t)))
    let em2 = "faixas = [\n  { ate_ms = 50.5, cor = \"#000000\" , },\n  { cor = \"#ffffff\" }, # fim\n]\n"
    confere(faixasDe(lerFaixas(em2))?.lista[0].ateMs == 50.5, erroDe(lerFaixas(em2)))
}

func pastaTemporaria() -> String {
    var modelo = Array("/tmp/netwatch-teste-XXXXXX".utf8CString)
    _ = mkdtemp(&modelo)
    return String(cString: modelo)
}

caso("queda aberta nao engole o sono") {
    var cfg = Config.padrao()!
    cfg.dir = pastaTemporaria()
    _ = cfg.resolveAlvos()
    let m = Monitor(cfg)!
    let t = agora()
    m.registra(Amostra(t: t, ms: 30), alvo: 0)
    m.registra(Amostra(t: t + 2, ms: nil), alvo: nil)  // caiu
    m.registra(Amostra(t: t + 4, ms: nil), alvo: nil)
    // dormiu 8 h e voltou com rede
    m.registra(Amostra(t: t + 4 + 8 * 3600, ms: 30), alvo: 0)
    confere(m.online)
    // fora = da queda ate a ultima falha + 1 intervalo, nao 8 h
    confere(abs(m.fora - 4) < 0.01, "fora = \(m.fora)")
    m.encerra()
    let ev = leArquivo(juntar(cfg.dir, "events.log")) ?? ""
    confere(ev.contains("VOLTOU\tficou fora 4s (sem confirmacao"), ev)
    confere(ev.contains("PAUSA"))
}

caso("samples.csv: grava e rele igual") {
    var cfg = Config.padrao()!
    cfg.dir = pastaTemporaria()
    _ = cfg.resolveAlvos()
    let m = Monitor(cfg)!
    let t = agora().rounded(.down) - 100
    for k in 0..<40 { m.registra(Amostra(t: t + Double(k) * 2, ms: k % 7 == 3 ? nil : Float(k) + 0.25), alvo: k % 7 == 3 ? nil : 0) }
    m.encerra()
    let csv = leArquivo(juntar(cfg.dir, "samples.csv")) ?? ""
    let linhas = csv.split(separator: "\n")
    confere(linhas.first == "horario,epoch,ms,alvo")
    confere(linhas.count == 41, "\(linhas.count)")
    confere(linhas[1].hasSuffix(",\(Int64(t)),0.2,1.1.1.1:443"), String(linhas[1]))  // 0.25: empate vai para o par
    confere(linhas[4].hasSuffix(",\(Int64(t + 6)),,"), String(linhas[4]))
    let m2 = Monitor(cfg)!
    confere(m2.hist.count == 40, "\(m2.hist.count)")
    confere(m2.hist[0].t == t && m2.hist[3].ms == nil && m2.hist[39].t == t + 78)
    confere(abs((m2.hist[5].ms ?? 0) - 5.2) < 0.01, "\(String(describing: m2.hist[5].ms))")
}

caso("samples.csv fora de ordem e com linha cortada") {
    var cfg = Config.padrao()!
    cfg.dir = pastaTemporaria()
    _ = cfg.resolveAlvos()
    let t = agora().rounded(.down) - 50
    var csv = "horario,epoch,ms,alvo\n"
    for k in [0, 2, 1, 3] { csv += "x,\(Int64(t) + Int64(k) * 2),\(k).5,1.1.1.1:443\n" }
    csv += "lixo sem virgula\nx,\(Int64(t) + 10),,\n2026-10-20T15:33:32-03:00,17925212122026"
    _ = escreveArquivo(juntar(cfg.dir, "samples.csv"), csv)
    let m = Monitor(cfg)!
    confere(m.hist.count == 5, "\(m.hist.count)")
    confere((0..<4).map { m.hist[$0].ms } == [0.5, 1.5, 2.5, 3.5], "\((0..<4).map { m.hist[$0].ms })")
    confere(m.hist[4].ms == nil && m.hist[4].t == t + 10)
}

caso("historico: corta 24h e acha o comeco da janela") {
    var h = Historico()
    let t0 = 1_792_000_000.0
    for k in 0..<50_000 { h.append(Amostra(t: t0 + Double(k) * 2, ms: Float(k % 100))) }
    let fim = t0 + 49_999 * 2
    h.descartaAte(fim - DIA)
    confere(h[0].t >= fim - DIA && h.count == Int(DIA / 2) + 1, "\(h.count) \(h[0].t - (fim - DIA))")
    let i = h.desde(fim - 60)
    confere(h.t(i) >= fim - 60 && (i == 0 || h.t(i - 1) < fim - 60))
    confere(h.count - i == 31, "\(h.count - i)")
    // precisao do tempo guardado (decimos de segundo)
    h.append(Amostra(t: fim + 2.04, ms: 1))
    confere(abs(h[h.count - 1].t - (fim + 2.0)) < 0.051)
}

caso("baldes: mediana com par e quartis") {
    var cfg = Config.padrao()!
    cfg.dir = pastaTemporaria()
    _ = cfg.resolveAlvos()
    let m = Monitor(cfg)!
    let t = agora() - 30
    for (k, v) in [10, 20, 30, 100].enumerated() { m.hist.append(Amostra(t: t + Double(k) * 2, ms: Float(v))) }
    let b = baldes(m, t0: t - 1, jan: 60, n: 1)
    confere(b[0]?.med == 25 && b[0]?.min == 10 && b[0]?.max == 100 && b[0]?.q1 == 20 && b[0]?.q3 == 100, "\(String(describing: b[0]))")
    confere(escalaPara(100) == 150 && passoGrade(150) == 50 && passoGrade(400) == 100)
}

caso("janela de config: valida ordena e aceita virgula") {
    func r(_ ms: String?, _ c: UInt8) -> Rascunho { Rascunho(ms: ms, claro: RGB(c, c, c), escuro: RGB(c, c, c)) }
    let f = faixasDe(valida([r("300", 3), r("100", 1), r("150,5", 2), r(nil, 9)]))
    confere(f?.lista.map(\.ateMs) == [100, 150.5, 300, nil])
    // a cor foi junto com a linha
    confere(f?.lista[0].cor == RGB(1, 1, 1) && f?.lista[1].cor == RGB(2, 2, 2) && f?.lista[3].cor == RGB(9, 9, 9))
    confere(erroDe(valida([r("abc", 1), r(nil, 2)])).contains("abc"))
    confere(!erroDe(valida([r("0", 1), r(nil, 2)])).isEmpty)
    confere(erroDe(valida([r("100", 1), r("100", 2), r(nil, 3)])).contains("mesmo limite"))
    // so a faixa "acima": tudo numa cor
    confere(faixasDe(valida([r(nil, 5)]))?.lista.count == 1)
}

caso("barra: histerese e texto de largura fixa") {
    let f = Faixas.padrao
    confere(classeMs(f, 50, .max) == 2)
    confere(classeMs(f, 110, 2) == 2, "110 ainda verde (limite 115)")
    confere(classeMs(f, 120, 2) == 3)
    confere(classeMs(f, 90, 3) == 3, "90 ainda amarelo (limite 85)")
    confere(classeMs(f, 80, 3) == 2)
    confere(textoMs(7.4) == "\u{2007}\u{2007}\u{2007}7 ms" && textoMs(1234) == "1234 ms")
}

caso("texto: dur, rfc3339, numeros") {
    confere(dur(59.9) == "59s" && dur(61) == "1m01s" && dur(3725) == "1h02m")
    let s = rfc3339(1_792_791_420)
    confere(s.count == 25 && s.contains("T") && (s.hasSuffix(":00")), s)
    confere(umaCasa(14.24) == "14.2" && umaCasa(0.05) == "0.1" && umaCasa(3) == "3.0")
    confere(numTexto(2.0) == "2" && numTexto(Float(150.5)) == "150.5")
    confere(numero(" 150,5 ") == 150.5 && numero("x") == nil && numero("-1") == nil)
}

print(falhas == 0 ? "\ntodos os testes passaram" : "\n\(falhas) falha(s)")
exit(falhas == 0 ? 0 : 1)
