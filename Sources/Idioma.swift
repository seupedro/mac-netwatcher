// Idioma da interface: portugues ou ingles.
//
// Os textos ficam onde sao usados, em pares tr("portugues", "english"), sem
// tabela de chaves nem pastas .lproj: sao poucas dezenas de frases e o idioma
// troca com o app aberto, pela janela de configuracoes.

import CoreFoundation
import Darwin

enum Idioma: String, CaseIterable {
    case pt, en
}

/// Idioma em uso. So muda dentro de Comum.com (ou antes de a sonda comecar):
/// quem le com a trava, inclusive a fila da sonda, ve um valor consistente.
var idiomaAtual: Idioma = idiomaDoSistema()

func tr(_ pt: String, _ en: String) -> String { idiomaAtual == .en ? en : pt }

/// NETWATCH_IDIOMA=pt|en (para testes e capturas de tela) passa por cima do
/// config.toml e do sistema.
func idiomaForcado() -> Idioma? {
    getenv("NETWATCH_IDIOMA").flatMap { Idioma(rawValue: String(cString: $0)) }
}

/// Primeiro idioma de Ajustes do Sistema → Geral → Idioma e Regiao:
/// portugues se for pt-*, ingles para qualquer outro.
func idiomaDoSistema() -> Idioma {
    // CoreFoundation direto: sem Foundation no nucleo
    guard let lista = CFLocaleCopyPreferredLanguages(), CFArrayGetCount(lista) > 0 else { return .en }
    let s = unsafeBitCast(CFArrayGetValueAtIndex(lista, 0), to: CFString.self)
    var buf = [CChar](repeating: 0, count: 64)
    guard CFStringGetCString(s, &buf, buf.count, CFStringBuiltInEncodings.UTF8.rawValue) else { return .en }
    return String(cString: buf).hasPrefix("pt") ? .pt : .en
}

/// O que vale: forcado, depois o do config.toml (nil = automatico), depois o
/// do sistema.
func idiomaEfetivo(_ escolhido: Idioma?) -> Idioma {
    idiomaForcado() ?? escolhido ?? idiomaDoSistema()
}
