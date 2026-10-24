// Estado dividido entre a fila da sonda e a thread principal, e a decisao do
// que a barra mostra.

import Darwin
import os

/// Com o menu fechado e a mesma cor, o numero da barra muda no maximo a cada 30 s.
let SEGURA_BARRA: Double = 30

/// O que a barra deve mostrar. `versao` sobe a cada troca, para a thread
/// principal saber se ja aplicou.
struct Barra {
    var classe: UInt8 = .max
    var txt = ""
    var ms: Float = 0
    var trocouEm: Double = 0
    var versao: UInt64 = 0
}

/// Tudo que as duas threads leem e escrevem, atras de uma trava so.
final class Comum: @unchecked Sendable {
    let m: Monitor
    var barra = Barra()
    var menuAberto = false
    var amostras = 0
    private let trava = OSAllocatedUnfairLock()

    init(_ m: Monitor) { self.m = m }

    func com<R>(_ f: (Comum) -> R) -> R {
        trava.lock()
        defer { trava.unlock() }
        return f(self)
    }
}

/// Mediana das ultimas 5 amostras boas (~10 s): um pico isolado nao mexe
/// na barra.
func latenciaSuave(_ m: Monitor) -> Float? {
    let h = m.hist
    var v: [Float] = []
    for k in stride(from: h.count - 1, through: max(0, h.count - 5), by: -1) {
        if let ms = h.ms(k) { v.append(ms) }
    }
    if v.isEmpty { return nil }
    v.sort()
    return v[v.count / 2]
}

/// Classe da barra (2 + indice da faixa) com histerese: para trocar de cor a
/// latencia tem que passar 15% alem do limite da faixa atual. Sem isso, uma
/// conexao oscilando perto de 100 ms trocava de cor ~10 vezes por minuto.
func classeMs(_ f: Faixas, _ ms: Float, _ atual: UInt8) -> UInt8 {
    let bruta = f.indice(ms)
    let c = Int(atual) - 2
    guard atual != .max, c >= 0, c < f.lista.count else { return UInt8(2 + bruta) }
    let sobe = bruta > c && (f.lista[c].ateMs.map { ms > $0 * 1.15 } ?? false)
    let desce = bruta < c && (f.lista[c - 1].ateMs.map { ms < $0 * 0.85 } ?? false)
    return UInt8(2 + (sobe || desce ? bruta : c))
}

/// Largura fixa com espaco de algarismo: o icone nao fica pulando na barra.
func textoMs(_ ms: Float) -> String {
    let n = String(Int(ms.rounded()))
    return String(repeating: "\u{2007}", count: max(0, 4 - n.count)) + n + " ms"
}

/// Decide o que a barra mostra; devolve true se mudou. Cada troca redesenha o
/// botao (Core Animation + Metal, com threads do sistema), entao com o menu
/// fechado: queda/volta e troca de cor aparecem na hora; o numero so muda a
/// cada 30 s e se andou pelo menos 10 ms e 15%. Com o menu aberto a barra
/// segue a ultima amostra, igual ao painel.
func barraMudou(_ c: Comum, aberto: Bool) -> Bool {
    let m = c.m
    let b = c.barra
    var classe: UInt8 = 0
    var ms: Float?
    if !m.medindo && !m.online {
        classe = 1
    } else if !m.medindo, let u = m.ultimo {
        let v = aberto ? u.ms : (latenciaSuave(m) ?? u.ms)
        classe = classeMs(m.faixas, v, b.classe)
        ms = v
    }
    let t = agora()
    let muda: Bool
    if classe != b.classe {
        muda = true
    } else if let v = ms {
        if aberto {
            muda = textoMs(v) != b.txt
        } else {
            let andou = abs(v - b.ms)
            muda = t - b.trocouEm >= SEGURA_BARRA && andou >= 10 && andou >= b.ms * 0.15
        }
    } else {
        muda = false
    }
    if !muda { return false }
    let txt = classe == 1 ? tr("sem rede", "offline") : ms.map(textoMs) ?? "…"
    c.barra = Barra(classe: classe, txt: txt, ms: ms ?? 0, trocouEm: t, versao: b.versao + 1)
    return true
}
