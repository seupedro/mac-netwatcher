// Sondagem: connect TCP nos alvos, sem ICMP (a movel da Claro bloqueia ping).
//
// Feito para gastar o minimo:
// - nenhuma thread fica de pe: um timer do GCD com folga de 10% (o kernel
//   junta o despertar dele com o de outros processos) dispara o teste numa
//   fila utility, e a thread do GCD volta para o pool quando ele termina;
// - os alvos de reserva sao testados juntos numa thread so, com connect nao
//   bloqueante e poll(), em vez de uma thread por alvo; o primeiro que
//   responde encerra a espera (e o mais rapido) e os outros sao abortados;
// - pausar para o timer de vez (suspend), sem thread parada num Condvar.

import Darwin
import Dispatch
import Foundation
import os

/// Depois que o Mac acorda, o Wi-Fi leva alguns segundos para reconectar:
/// ate a primeira resposta (ou ate passar este tempo) falha nao conta.
let CARENCIA: Double = 20

/// ip:porta resolvido uma vez so, na partida.
struct Endereco {
    var sa = sockaddr_storage()
    var len: socklen_t = 0
    /// "1.1.1.1:443" (vai no samples.csv)
    var rotulo = ""
    /// "1.1.1.1"
    var ip = ""

    init?(_ texto: String) {
        var host = texto
        var porta = "443"
        if let p = texto.lastIndex(of: ":") {
            host = String(texto[..<p])
            porta = String(texto[texto.index(after: p)...])
        }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        var dica = addrinfo()
        dica.ai_socktype = SOCK_STREAM
        dica.ai_flags = AI_NUMERICSERV
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, porta, &dica, &res) == 0, let r = res else { return nil }
        defer { freeaddrinfo(res) }
        len = r.pointee.ai_addrlen
        withUnsafeMutableBytes(of: &sa) { d in
            d.copyMemory(from: UnsafeRawBufferPointer(start: r.pointee.ai_addr, count: Int(len)))
        }
        var h = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var s = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let ok = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, len, &h, socklen_t(h.count), &s, socklen_t(s.count), NI_NUMERICHOST | NI_NUMERICSERV)
            }
        }
        guard ok == 0 else { return nil }
        ip = String(cString: h)
        rotulo = sa.ss_family == sa_family_t(AF_INET6) ? "[\(ip)]:\(String(cString: s))" : "\(ip):\(String(cString: s))"
    }
}

/// SO_LINGER com tempo 0: o close() manda um RST em vez da troca de FIN.
/// Menos pacotes por teste e nenhum socket preso em TIME_WAIT.
func fechaComRst(_ fd: Int32) {
    var l = linger(l_onoff: 1, l_linger: 0)
    setsockopt(fd, SOL_SOCKET, SO_LINGER, &l, socklen_t(MemoryLayout<linger>.size))
    close(fd)
}

/// Abre um connect em cada alvo de `quais` ao mesmo tempo e espera com um
/// poll() so. Devolve a latencia do primeiro que completar e o indice dele.
func testa(_ alvos: [Endereco], _ quais: [Int], timeout: Double) -> (ms: Float, alvo: Int)? {
    var fds: [pollfd] = []
    var dono: [Int] = []
    var inicio: [UInt64] = []
    fds.reserveCapacity(quais.count)
    defer { for p in fds where p.fd >= 0 { fechaComRst(p.fd) } }
    for i in quais {
        var e = alvos[i]
        let fd = socket(Int32(e.sa.ss_family), SOCK_STREAM, IPPROTO_TCP)
        if fd < 0 { continue }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var um: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &um, socklen_t(MemoryLayout<Int32>.size))
        let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let r = withUnsafePointer(to: &e.sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, e.len) }
        }
        if r == 0 {
            // loopback pode completar na hora
            let ms = Float(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6
            fechaComRst(fd)
            return (ms, i)
        }
        if errno != EINPROGRESS {
            close(fd)
            continue
        }
        fds.append(pollfd(fd: fd, events: Int16(POLLOUT), revents: 0))
        dono.append(i)
        inicio.append(t0)
    }
    let limite = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + UInt64(timeout * 1e9)
    var vivos = fds.count
    while vivos > 0 {
        let agora = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if agora >= limite { break }
        let espera = Int32(min((limite - agora + 999_999) / 1_000_000, UInt64(Int32.max)))
        let n = poll(&fds, nfds_t(fds.count), espera)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { break }
        let fim = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for k in fds.indices where fds[k].fd >= 0 && fds[k].revents != 0 {
            var erro: Int32 = 0
            var tam = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fds[k].fd, SOL_SOCKET, SO_ERROR, &erro, &tam)
            if erro == 0 && fds[k].revents & Int16(POLLOUT) != 0 {
                return (Float(fim - inicio[k]) / 1e6, dono[k])
            }
            close(fds[k].fd)
            fds[k].fd = -1  // poll ignora fd negativo
            vivos -= 1
        }
    }
    return nil
}

/// Laco de medicao. Para gastar menos radio e bateria, com a conexao de pe
/// testa um alvo so: sempre o primeiro (1.1.1.1, o de menor latencia daqui).
/// Os outros so entram no ciclo em que ele falha, e todos juntos enquanto a
/// conexao estiver caida; no ciclo seguinte volta a tentar o primeiro.
///
/// Dois jeitos de esperar o proximo teste (NETWATCH_SONDA=gcd|fio), para
/// medir qual gasta menos:
/// - gcd: timer do GCD com folga de 10%, sem thread fixa;
/// - fio: uma thread so, que dorme num kqueue com timer de folga de 10%
///   (NOTE_LEEWAY) e acorda para retomar por um EVFILT_USER.
final class Sonda: @unchecked Sendable {
    enum Modo { case gcd, fio }

    let alvos: [Endereco]
    let intervalo: Double
    let timeout: Double
    let modo: Modo
    /// chamada na fila/thread da sonda a cada amostra que vale
    private let entrega: (Amostra, Int?) -> Void
    // modo gcd
    private let fila = DispatchQueue(label: "xyz.paralaxe.netwatch.sonda", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var suspenso = true  // comeca inativo: activate() conta como resume
    // modo fio
    private var kq: Int32 = -1
    // so mexidos dentro do ciclo (fila ou thread da sonda)
    private var caido = false
    private var carenciaAte: Double?
    /// lido no fim de cada teste (pode mudar no meio dele)
    private let parado = OSAllocatedUnfairLock(initialState: false)

    init(alvos: [Endereco], intervalo: Double, timeout: Double, modo: Modo = .gcd,
         entrega: @escaping (Amostra, Int?) -> Void) {
        self.alvos = alvos
        self.intervalo = intervalo
        self.timeout = timeout
        self.modo = modo
        self.entrega = entrega
        if modo == .gcd {
            let t = DispatchSource.makeTimerSource(flags: [], queue: fila)
            t.setEventHandler { [weak self] in self?.ciclo() }
            timer = t
        } else {
            kq = kqueue()
            var ev = kevent64_s(ident: 1, filter: Int16(EVFILT_USER), flags: UInt16(EV_ADD | EV_CLEAR),
                                fflags: 0, data: 0, udata: 0, ext: (0, 0))
            kevent64(kq, &ev, 1, nil, 0, 0, nil)
        }
    }

    deinit {
        // o GCD aborta o processo se uma fonte for solta parada ou sem nunca
        // ter sido ligada
        timer?.cancel()
        if suspenso { timer?.resume() }
    }

    private func agenda() {
        timer?.schedule(deadline: .now(), repeating: .milliseconds(Int(intervalo * 1000)),
                        leeway: .milliseconds(Int(intervalo * 100)))
    }

    func inicia() {
        switch modo {
        case .gcd:
            fila.async {
                self.agenda()
                self.suspenso = false
                self.timer?.activate()
            }
        case .fio:
            let t = Thread { [self] in laco() }
            t.qualityOfService = .utility
            t.stackSize = 128 << 10
            t.name = "sonda"
            t.start()
        }
    }

    /// Mac indo dormir: para o timer. Um teste em andamento e descartado.
    func pausa() {
        parado.withLock { $0 = true }
        guard modo == .gcd else { return }  // a thread ve o aviso quando acordar
        fila.async {
            if !self.suspenso {
                self.timer?.suspend()
                self.suspenso = true
            }
        }
    }

    func retoma() {
        parado.withLock { $0 = false }
        switch modo {
        case .gcd:
            fila.async {
                self.carenciaAte = monotonico() + CARENCIA
                self.caido = true  // na volta testa os tres juntos
                if self.suspenso {
                    self.agenda()
                    self.timer?.resume()
                    self.suspenso = false
                }
            }
        case .fio:
            var ev = kevent64_s(ident: 1, filter: Int16(EVFILT_USER), flags: 0,
                                fflags: UInt32(NOTE_TRIGGER), data: 0, udata: 0, ext: (0, 0))
            kevent64(kq, &ev, 1, nil, 0, 0, nil)
        }
    }

    var estaParado: Bool { parado.withLock { $0 } }

    /// Modo fio: testa, dorme ate completar o intervalo (com folga) e repete.
    private func laco() {
        var saida = kevent64_s()
        // horario fixo (t0, t0 + 2 s, t0 + 4 s...): o atraso que a folga do
        // timer introduz nao se acumula (dormindo "2 s - duracao do teste",
        // o periodo real ficava em 2,11 s)
        var proximo = monotonico()
        while true {
            if estaParado {
                // parado: dorme sem timer ate o retoma()
                while estaParado { kevent64(kq, nil, 0, &saida, 1, 0, nil) }
                carenciaAte = monotonico() + CARENCIA
                caido = true
                proximo = monotonico()
            }
            ciclo()
            proximo += intervalo
            let agora = monotonico()
            if proximo < agora + 0.05 { proximo = agora + 0.05 }  // teste demorado: nao tenta compensar
            let resta = proximo - agora
            var ev = kevent64_s(ident: 2, filter: Int16(EVFILT_TIMER), flags: UInt16(EV_ADD | EV_ONESHOT),
                                fflags: UInt32(NOTE_NSECONDS | NOTE_LEEWAY), data: Int64(resta * 1e9),
                                udata: 0, ext: (0, UInt64(intervalo * 0.1 * 1e9)))
            kevent64(kq, &ev, 1, &saida, 1, 0, nil)
        }
    }

    private func ciclo() {
        if estaParado { return }
        let t = agora()
        let r: (ms: Float, alvo: Int)?
        if caido {
            r = testa(alvos, Array(alvos.indices), timeout: timeout)
        } else {
            r = testa(alvos, [0], timeout: timeout) ?? testa(alvos, Array(alvos.indices.dropFirst()), timeout: timeout)
        }
        caido = r == nil
        if r != nil || carenciaAte.map({ monotonico() >= $0 }) == true { carenciaAte = nil }
        // Mac indo dormir no meio do teste (a falha seria a rede desligando)
        // ou Wi-Fi ainda reconectando depois de acordar: nao entrega
        let descarta = estaParado || (r == nil && carenciaAte != nil)
        if !descarta { entrega(Amostra(t: t, ms: r?.ms), r?.alvo) }
    }
}

