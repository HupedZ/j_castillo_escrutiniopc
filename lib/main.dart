import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

const _baseUrl = 'https://api.thisiswanay.com';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Escrutinio Mesa',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1A237E)),
        useMaterial3: true,
      ),
      home: const EscrutinioPage(),
    );
  }
}

// ── Datos de listas ─────────────────────────────────────────────────────────

class _Lista {
  final String codigo;
  final Color  color;
  final bool   pref;
  const _Lista(this.codigo, this.color, {this.pref = true});
  String get label => codigo == 'B' ? 'En Blanco' : 'Lista $codigo';
  Color  get fg    => color.computeLuminance() > 0.45 ? Colors.black87 : Colors.white;
}

const _kListasInt = [
  _Lista('1',    Color(0xFFD93A1A)),
  _Lista('6',    Color(0xFF8AAACB)),
  _Lista('2026', Color(0xFF4A1A6B)),
  _Lista('B',    Color(0xFFBDBDBD), pref: false),
];

const _kListasCon = [
  _Lista('1',  Color(0xFFD93A1A)),
  _Lista('3',  Color(0xFF1B4D2B)),
  _Lista('4',  Color(0xFFF0B800)),
  _Lista('6',  Color(0xFF8AAACB)),
  _Lista('9',  Color(0xFF7B3535)),
  _Lista('20', Color(0xFF5C35B0)),
  _Lista('68', Color(0xFFC9A060)),
  _Lista('B',  Color(0xFFBDBDBD), pref: false),
];

// ── Pantalla principal ───────────────────────────────────────────────────────

class EscrutinioPage extends StatefulWidget {
  const EscrutinioPage({super.key});

  @override
  State<EscrutinioPage> createState() => _EscrutinioPageState();
}

class _EscrutinioPageState extends State<EscrutinioPage> {
  // codigo -> nombre
  List<(String, String)> _locales = [];
  String? _localSel;   // almacena loc_codigo
  bool         _cargandoLocales = true;
  final        _localFN         = FocusNode();

  late final TextEditingController                       _mesaCtrl;
  late final Map<String, TextEditingController>          _intCtrl;
  late final Map<String, TextEditingController>          _conTotalCtrl;
  late final Map<String, List<TextEditingController>>    _conPrefCtrl;
  late final List<FocusNode>                             _foci;

  bool   _guardando        = false;
  bool   _buscandoMesa     = false;
  bool   _leyendoImagen    = false;
  bool   _esModificacion   = false;
  bool   _mesaConfirmada   = false;
  String _statusMsg = '';
  bool   _statusOk  = true;

  // ── Índices de foco ─────────────────────────────────────────────────────
  // 0       : mesa
  // 1..4    : intendente (en orden _kListasInt)
  // 5+      : concejal — cada lista con pref ocupa 13 slots (total + 12 pref),
  //           cada lista sin pref ocupa 1 slot.

  int _iMesa()                 => 0;
  int _iInt(int li)            => 1 + li;
  int _iConTotal(int li) {
    int off = 1 + _kListasInt.length; // 5
    for (int i = 0; i < li; i++) {
      off += 1 + (_kListasCon[i].pref ? 12 : 0);
    }
    return off;
  }
  int _iConPref(int li, int pi) => _iConTotal(li) + 1 + pi;

  void _focusAt(int i) {
    if (i >= 0 && i < _foci.length) _foci[i].requestFocus();
  }

  // Registra navegación con flechas en el FocusNode indicado.
  // Flecha abajo = onNext, flecha arriba = campo anterior en la secuencia.
  void _setupKeyNav(int idx, VoidCallback onNext) {
    _foci[idx].onKeyEvent = (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        onNext();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp && idx > 0) {
        _focusAt(idx - 1);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
  }

  // ── Init / dispose ──────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();

    _mesaCtrl     = TextEditingController();
    _intCtrl      = {for (final l in _kListasInt) l.codigo: TextEditingController()};
    _conTotalCtrl = {for (final l in _kListasCon) l.codigo: TextEditingController()};
    _conPrefCtrl  = {
      for (final l in _kListasCon)
        if (l.pref) l.codigo: List.generate(12, (_) => TextEditingController(text: '0')),
    };

    int count = 1 + _kListasInt.length;
    for (final l in _kListasCon) count += 1 + (l.pref ? 12 : 0);
    _foci = List.generate(count, (_) => FocusNode());

    // Listeners para totales en tiempo real
    for (final c in _intCtrl.values) c.addListener(_onConcejalChange);
    for (final l in _kListasCon) {
      _conTotalCtrl[l.codigo]!.addListener(_onConcejalChange);
      if (l.pref) {
        for (final c in _conPrefCtrl[l.codigo]!) {
          c.addListener(_onConcejalChange);
        }
      }
    }

    _cargarLocales();
  }

  void _onConcejalChange() => setState(() {});

  int _sumPrefs(String lista) {
    final prefs = _conPrefCtrl[lista];
    if (prefs == null) return 0;
    return prefs.fold(0, (s, c) => s + (int.tryParse(c.text) ?? 0));
  }

  int _sumInt() => _intCtrl.values
      .fold(0, (s, c) => s + (int.tryParse(c.text) ?? 0));

  int _sumConTotales() => _conTotalCtrl.values
      .fold(0, (s, c) => s + (int.tryParse(c.text) ?? 0));

  @override
  void dispose() {
    _mesaCtrl.dispose();
    for (final c in _intCtrl.values) c.dispose();
    for (final c in _conTotalCtrl.values) c.dispose();
    for (final ll in _conPrefCtrl.values) {
      for (final c in ll) c.dispose();
    }
    for (final f in _foci) f.dispose();
    _localFN.dispose();
    super.dispose();
  }

  // ── API ─────────────────────────────────────────────────────────────────

  Future<void> _cargarLocales() async {
    try {
      final res  = await http.get(Uri.parse('$_baseUrl/checker/locales'));
      final data = jsonDecode(res.body) as Map;
      if (data['ok'] == true) {
        setState(() {
          _locales = (data['locales'] as List)
              .map((l) => (
                    (l['loc_codigo'] as Object).toString(),
                    (l['loc_nombre'] as String).trim(),
                  ))
              .toList();
          _cargandoLocales = false;
        });
        return;
      }
    } catch (_) {}
    setState(() => _cargandoLocales = false);
  }

  // ── Acciones ─────────────────────────────────────────────────────────────

  void _nuevo() {
    _mesaCtrl.clear();
    for (final c in _intCtrl.values) c.clear();
    for (final c in _conTotalCtrl.values) c.clear();
    for (final ll in _conPrefCtrl.values) {
      for (final c in ll) c.text = '0';
    }
    setState(() {
      _statusMsg       = '';
      _esModificacion  = false;
      _mesaConfirmada  = false;
    });
    // Si ya tiene local seleccionado, va directo a mesa; si no, a local
    if (_localSel != null) {
      _foci[_iMesa()].requestFocus();
    } else {
      _localFN.requestFocus();
    }
  }

  Future<void> _verificarMesa() async {
    final mesa = _mesaCtrl.text.trim();
    if (mesa.isEmpty) {
      _focusAt(_iInt(0));
      return;
    }
    if (_localSel == null) return;
    setState(() => _buscandoMesa = true);
    try {
      final url = '$_baseUrl/checker/escrutinio-mesa/$mesa'
          '?local=${Uri.encodeComponent(_localSel!)}';
      final res = await http.get(Uri.parse(url));
      if (!mounted) return;
      final data = jsonDecode(res.body) as Map;
      if (data['ok'] == true && data['data'] != null) {
        final d = data['data'] as Map;
        final int_ = (d['intendente'] as Map?) ?? {};
        final con  = (d['concejal']   as Map?) ?? {};
        for (final l in _kListasInt) {
          _intCtrl[l.codigo]!.text = (int_[l.codigo] ?? 0).toString();
        }
        for (final l in _kListasCon) {
          final ld = (con[l.codigo] as Map?) ?? {};
          _conTotalCtrl[l.codigo]!.text = (ld['total'] ?? 0).toString();
          if (l.pref) {
            final prefs = (ld['preferencias'] as Map?) ?? {};
            for (int i = 0; i < 12; i++) {
              _conPrefCtrl[l.codigo]![i].text =
                  (prefs['${i + 1}'] ?? 0).toString();
            }
          }
        }
        setState(() {
          _esModificacion = true;
          _mesaConfirmada = true;
        });
      } else {
        setState(() {
          _esModificacion = false;
          _mesaConfirmada = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() {
        _esModificacion = false;
        _mesaConfirmada = true;
      });
    } finally {
      if (mounted) {
        setState(() => _buscandoMesa = false);
        _focusAt(_iInt(0));
      }
    }
  }

  Future<void> _finalizar() async {
    final mesa = _mesaCtrl.text.trim();
    if (mesa.isEmpty) {
      _setStatus('Falta el número de mesa', ok: false);
      _focusAt(_iMesa());
      return;
    }

    // Validar que totales de intendente y concejal coincidan
    final totalInt = _sumInt();
    final totalCon = _sumConTotales();
    if (totalInt != totalCon) {
      final diff = totalCon - totalInt;
      _setStatus(
        diff > 0
            ? 'Error: concejal tiene $diff votos de más que intendente ($totalCon vs $totalInt)'
            : 'Error: faltan ${-diff} votos en concejal ($totalCon vs $totalInt)',
        ok: false,
      );
      return;
    }

    // Validar sumas de preferencias
    for (final l in _kListasCon) {
      if (!l.pref) continue;
      final total = int.tryParse(_conTotalCtrl[l.codigo]!.text) ?? 0;
      final suma  = _sumPrefs(l.codigo);
      if (suma > total) {
        _setStatus(
          'Error Lista ${l.codigo}: preferencias ($suma) superan el total ($total)',
          ok: false,
        );
        return;
      }
    }

    setState(() => _guardando = true);
    try {
      final intendente = <String, int>{
        for (final l in _kListasInt)
          l.codigo: int.tryParse(_intCtrl[l.codigo]!.text) ?? 0,
      };

      final concejal = <String, dynamic>{};
      for (final l in _kListasCon) {
        final total = int.tryParse(_conTotalCtrl[l.codigo]!.text) ?? 0;
        if (l.pref) {
          final prefs = {
            for (int i = 0; i < 12; i++)
              '${i + 1}': int.tryParse(_conPrefCtrl[l.codigo]![i].text) ?? 0,
          };
          concejal[l.codigo] = {'total': total, 'preferencias': prefs};
        } else {
          concejal[l.codigo] = {'total': total};
        }
      }

      final res = await http.post(
        Uri.parse('$_baseUrl/checker/escrutinio-mesa'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'mesa': mesa,
          if (_localSel != null) 'local': _localSel,
          'intendente': intendente,
          'concejal': concejal,
        }),
      );

      if (!mounted) return;
      final data = jsonDecode(res.body) as Map;
      if (data['ok'] == true) {
        _setStatus('✓ Mesa $mesa guardada correctamente', ok: true);
      } else {
        _setStatus(data['message']?.toString() ?? 'Error al guardar', ok: false);
      }
    } catch (_) {
      if (mounted) _setStatus('Error de conexión', ok: false);
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  void _setStatus(String msg, {required bool ok}) {
    setState(() {
      _statusMsg = msg;
      _statusOk  = ok;
    });
  }

  // ── QR ──────────────────────────────────────────────────────────────────

  Future<void> _escanearQR() async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leer certificado QR'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Escanee el QR del certificado oficial con un lector USB o pegue '
                'el contenido copiado desde su celular:',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autofocus: true,
                maxLines: 4,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  hintText: 'REC 9A...',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => Navigator.pop(ctx, ctrl.text),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Aplicar'),
          ),
        ],
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      _procesarQR(result.trim());
    }
  }

  void _procesarQR(String raw) {
    try {
      String hex = raw;
      if (hex.startsWith('REC ')) hex = hex.substring(4);
      else if (hex.startsWith('REC')) hex = hex.substring(3);
      hex = hex.replaceAll(RegExp(r'\s+'), '');
      if (hex.length % 2 != 0) {
        _setStatus('QR inválido: longitud impar', ok: false);
        return;
      }
      final bytes = Uint8List(hex.length ~/ 2);
      for (int i = 0; i < bytes.length; i++) {
        bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      }

      // Buscar header zlib (78 9C / 78 DA / 78 01 / 78 5E)
      int zlibStart = -1;
      for (int i = 0; i < bytes.length - 1; i++) {
        if (bytes[i] == 0x78) {
          final b = bytes[i + 1];
          if (b == 0x9C || b == 0xDA || b == 0x01 || b == 0x5E) {
            zlibStart = i;
            break;
          }
        }
      }
      if (zlibStart < 0) {
        _setStatus('QR: no se encontró bloque comprimido', ok: false);
        return;
      }

      final decompressed = Uint8List.fromList(
        io.ZLibDecoder().convert(bytes.sublist(zlibStart)));

      if (decompressed.length < 16) {
        _setStatus('QR: datos insuficientes tras descomprimir', ok: false);
        return;
      }

      // Detectar tipo por bytes 6-7 del payload descomprimido
      final b6 = decompressed[6];
      final b7 = decompressed[7];

      if (b6 == 0xF0 && b7 == 0x01) {
        _aplicarQRIntendente(decompressed);
      } else if (b6 == 0x70 && b7 == 0x0B) {
        _setStatus('Certificado de Junta Municipal: decodificación en proceso', ok: false);
      } else {
        _setStatus('QR: tipo de certificado no reconocido (${b6.toRadixString(16)} ${b7.toRadixString(16)})', ok: false);
      }
    } catch (e) {
      _setStatus('Error procesando QR: $e', ok: false);
    }
  }

  static int _bitsMSB(Uint8List data, int startBit, int nBits) {
    int result = 0;
    for (int i = 0; i < nBits; i++) {
      final byteIdx = (startBit + i) ~/ 8;
      final bitIdx  = 7 - ((startBit + i) % 8);
      if (byteIdx < data.length) {
        result = (result << 1) | ((data[byteIdx] >> bitIdx) & 1);
      }
    }
    return result;
  }

  void _aplicarQRIntendente(Uint8List data) {
    final l1    = _bitsMSB(data, 67, 8);
    final l6    = _bitsMSB(data, 75, 8);
    final l2026 = _bitsMSB(data, 83, 8);
    final blc   = _bitsMSB(data, 91, 8);
    final tot   = _bitsMSB(data, 107, 8);
    final nul   = _bitsMSB(data, 115, 8);

    setState(() {
      _intCtrl['1']!.text    = l1.toString();
      _intCtrl['6']!.text    = l6.toString();
      _intCtrl['2026']!.text = l2026.toString();
      _intCtrl['B']!.text    = blc.toString();
    });
    _setStatus(
      'QR Intendente cargado — L1:$l1  L6:$l6  L2026:$l2026  Blanco:$blc  Nulo:$nul  Total:$tot',
      ok: true,
    );
  }

  // ── Lector de imagen (Gemini) ────────────────────────────────────────────

  static io.File get _keyFile {
    final home = io.Platform.environment['USERPROFILE']   // Windows
        ?? io.Platform.environment['HOME']               // macOS/Linux
        ?? '.';
    return io.File('$home/.jce_gemini_key');
  }

  Future<String?> _obtenerGeminiKey() async {
    if (await _keyFile.exists()) {
      final k = (await _keyFile.readAsString()).trim();
      if (k.isNotEmpty) return k;
    }
    if (!mounted) return null;
    final ctrl = TextEditingController();
    final key = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Configurar API key de Gemini'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Para leer certificados por imagen necesitás una API key '
                'de Google AI Studio (gratuita).\n\n'
                '1. Entrá a aistudio.google.com\n'
                '2. Hacé clic en "Get API key"\n'
                '3. Pegá la key acá:',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autofocus: true,
                obscureText: true,
                decoration: const InputDecoration(
                  hintText: 'AIza...',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => Navigator.pop(ctx, ctrl.text),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (key != null && key.trim().isNotEmpty) {
      await _keyFile.writeAsString(key.trim());
      return key.trim();
    }
    return null;
  }

  Future<void> _leerImagen() async {
    final apiKey = await _obtenerGeminiKey();
    if (apiKey == null) return;

    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    if (picked == null || picked.files.isEmpty) return;

    final path = picked.files.first.path;
    if (path == null) return;

    setState(() => _leyendoImagen = true);
    _setStatus('Leyendo certificado con IA…', ok: true);

    try {
      final imageBytes = await io.File(path).readAsBytes();
      final base64Image = base64Encode(imageBytes);
      final ext = picked.files.first.extension?.toLowerCase() ?? 'jpg';
      final mime = ext == 'png' ? 'image/png'
                 : ext == 'webp' ? 'image/webp'
                 : 'image/jpeg';

      final res = await http.post(
        Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/'
          'gemini-2.0-flash:generateContent?key=$apiKey',
        ),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'contents': [
            {
              'parts': [
                {
                  'inline_data': {'mime_type': mime, 'data': base64Image},
                },
                {
                  'text': '''Sos un asistente que lee actas de escrutinio de elecciones municipales del Paraguay (TSJE).

Extraé los votos de esta acta. Las secciones posibles son INTENDENTE y JUNTA MUNICIPAL (concejal).

Para INTENDENTE las listas son: 1, 6, 2026, B (votos en blanco).
Para JUNTA MUNICIPAL (concejal) las listas son: 1, 3, 4, 6, 9, 20, 68, B (votos en blanco).

Devolvé ÚNICAMENTE el JSON (sin markdown, sin explicación) en este formato exacto:
{"intendente":{"1":0,"6":0,"2026":0,"B":0},"concejal":{"1":0,"3":0,"4":0,"6":0,"9":0,"20":0,"68":0,"B":0}}

Si una sección no aparece en el acta, devolvé null para esa clave. Si una lista no tiene votos, devolvé 0.''',
                },
              ],
            }
          ],
          'generationConfig': {'temperature': 0},
        }),
      );

      if (!mounted) return;

      if (res.statusCode != 200) {
        // API key inválida: borrar para que pida de nuevo
        if (res.statusCode == 400 || res.statusCode == 403) {
          try { await _keyFile.delete(); } catch (_) {}
        }
        _setStatus('Error Gemini ${res.statusCode}: ${res.body}', ok: false);
        return;
      }

      final body = jsonDecode(res.body) as Map;
      final text = ((((body['candidates'] as List?)?.firstOrNull
              as Map?)?['content'] as Map?)?['parts'] as List?)
          ?.firstOrNull
          ?['text'] as String?;

      if (text == null || text.trim().isEmpty) {
        _setStatus('Gemini no devolvió texto', ok: false);
        return;
      }

      // Limpiar posible markdown ```json ... ```
      final clean = text.trim()
          .replaceAll(RegExp(r'^```[a-z]*\n?', multiLine: false), '')
          .replaceAll('```', '')
          .trim();

      final json = jsonDecode(clean) as Map;
      _aplicarDatosImagen(json);
    } catch (e) {
      if (mounted) _setStatus('Error: $e', ok: false);
    } finally {
      if (mounted) setState(() => _leyendoImagen = false);
    }
  }

  void _aplicarDatosImagen(Map json) {
    int cambios = 0;
    final intMap = json['intendente'] as Map?;
    if (intMap != null) {
      for (final l in _kListasInt) {
        final v = intMap[l.codigo];
        if (v != null) {
          _intCtrl[l.codigo]!.text = v.toString();
          cambios++;
        }
      }
    }
    final conMap = json['concejal'] as Map?;
    if (conMap != null) {
      for (final l in _kListasCon) {
        final v = conMap[l.codigo];
        if (v != null) {
          _conTotalCtrl[l.codigo]!.text = v.toString();
          cambios++;
        }
      }
    }
    setState(() {});
    if (cambios > 0) {
      _setStatus('Imagen leída: $cambios campos cargados', ok: true);
    } else {
      _setStatus('No se encontraron datos en la imagen', ok: false);
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _finalizar,
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): _nuevo,
        const SingleActivator(LogicalKeyboardKey.keyQ, control: true): () {
          if (_mesaConfirmada) _escanearQR();
        },
        const SingleActivator(LogicalKeyboardKey.keyI, control: true): () {
          if (_mesaConfirmada) _leerImagen();
        },
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF0F2F5),
        appBar: AppBar(
          backgroundColor: const Color(0xFF1A237E),
          foregroundColor: Colors.white,
          title: const Text('Escrutinio Mesa'),
          actions: [
            if (_guardando || _leyendoImagen)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2),
                  ),
                ),
              )
            else ...[
              if (_mesaConfirmada) ...[
                TextButton.icon(
                  onPressed: _leerImagen,
                  icon: const Icon(Icons.document_scanner, color: Colors.white70, size: 18),
                  label: const Text('Leer imagen',
                      style: TextStyle(color: Colors.white70, fontSize: 12)),
                ),
                TextButton.icon(
                  onPressed: _escanearQR,
                  icon: const Icon(Icons.qr_code_scanner, color: Colors.white70, size: 18),
                  label: const Text('Leer QR',
                      style: TextStyle(color: Colors.white70, fontSize: 12)),
                ),
              ],
              TextButton.icon(
                onPressed: _finalizar,
                icon: const Icon(Icons.save_outlined, color: Colors.white70, size: 18),
                label: Text(
                  _esModificacion ? 'Modificar  Ctrl+F' : 'Finalizar  Ctrl+F',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
              TextButton.icon(
                onPressed: _nuevo,
                icon: const Icon(Icons.add, color: Colors.white70, size: 18),
                label: const Text('Nueva Mesa  Ctrl+N',
                    style: TextStyle(color: Colors.white70, fontSize: 12)),
              ),
            ],
            const SizedBox(width: 8),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_esModificacion)
              Container(
                color: Colors.orange[800],
                padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 16),
                child: Row(
                  children: [
                    const Icon(Icons.edit, color: Colors.white, size: 15),
                    const SizedBox(width: 8),
                    Text(
                      'Modificando mesa ${_mesaCtrl.text}',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ],
                ),
              ),
            if (_statusMsg.isNotEmpty)
              Container(
                color: _statusOk ? Colors.green[700] : Colors.red[700],
                padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 16),
                child: Text(
                  _statusMsg,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildCabecera(),
                    const SizedBox(height: 12),
                    Opacity(
                      opacity: _mesaConfirmada ? 1.0 : 0.4,
                      child: IgnorePointer(
                        ignoring: !_mesaConfirmada,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildIntendente(),
                            const SizedBox(height: 12),
                            _buildConcejal(),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Cabecera ──────────────────────────────────────────────────────────────

  Widget _buildCabecera() {
    _setupKeyNav(_iMesa(), () => _verificarMesa());
    final localBloqueado = _mesaConfirmada;
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            // Local PRIMERO — obligatorio antes de ingresar mesa
            Expanded(
              child: Opacity(
                opacity: localBloqueado ? 0.6 : 1.0,
                child: IgnorePointer(
                  ignoring: localBloqueado,
                  child: DropdownButtonFormField<String>(
                    focusNode: _localFN,
                    decoration: const InputDecoration(
                      labelText: 'Local de votación',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                    value: _localSel,
                    hint: Text(_cargandoLocales ? 'Cargando...' : 'Seleccionar local primero...'),
                    items: _locales
                        .map((l) => DropdownMenuItem(value: l.$1, child: Text(l.$2)))
                        .toList(),
                    onChanged: (v) {
                      setState(() {
                        _localSel = v;
                        // Si cambia el local, hay que re-confirmar mesa
                        if (_mesaConfirmada) {
                          _mesaConfirmada = false;
                          _esModificacion = false;
                          _mesaCtrl.clear();
                        }
                      });
                      _foci[_iMesa()].requestFocus();
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            // Mesa — solo activa cuando hay local seleccionado
            Opacity(
              opacity: _localSel != null ? 1.0 : 0.4,
              child: IgnorePointer(
                ignoring: _localSel == null,
                child: SizedBox(
                  width: 180,
                  child: _NumField(
                    label: 'Mesa Nº',
                    ctrl: _mesaCtrl,
                    focusNode: _foci[_iMesa()],
                    onNext: _verificarMesa,
                    autofocus: false,
                    loading: _buscandoMesa,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Intendente ────────────────────────────────────────────────────────────

  Widget _buildIntendente() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('INTENDENTE',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A237E),
                    letterSpacing: 0.5)),
            const SizedBox(height: 12),
            ..._kListasInt.asMap().entries.map((e) {
              final li     = e.key;
              final l      = e.value;
              final isLast = li == _kListasInt.length - 1;
              final onNext = isLast
                  ? () => _focusAt(_iConTotal(0))
                  : () => _focusAt(_iInt(li + 1));
              _setupKeyNav(_iInt(li), onNext);
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    _ListaChip(lista: l, width: 130),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 130,
                      child: _NumField(
                        label: 'Votos',
                        ctrl: _intCtrl[l.codigo]!,
                        focusNode: _foci[_iInt(li)],
                        onNext: onNext,
                        bold: true,
                      ),
                    ),
                  ],
                ),
              );
            }),
            // ── Resumen totales ────────────────────────────────────────
            const Divider(height: 16),
            Builder(builder: (_) {
              final totalInt = _sumInt();
              final totalCon = _sumConTotales();
              final ok       = totalCon == totalInt;
              final hayDatos = totalInt > 0 || totalCon > 0;
              return Row(
                children: [
                  _TotalChip(
                    label: 'Total intendente',
                    valor: totalInt,
                    color: const Color(0xFF1A237E),
                  ),
                  const SizedBox(width: 12),
                  _TotalChip(
                    label: 'Total concejal cargado',
                    valor: totalCon,
                    color: !hayDatos
                        ? Colors.grey
                        : ok
                            ? Colors.green[700]!
                            : Colors.red[700]!,
                  ),
                  if (hayDatos && !ok) ...[
                    const SizedBox(width: 10),
                    Text(
                      () {
                        final diff = totalInt - totalCon;
                        return diff > 0
                            ? 'Faltan $diff votos en concejal'
                            : 'Sobran ${-diff} votos en concejal';
                      }(),
                      style: TextStyle(
                          fontSize: 12,
                          color: Colors.red[700],
                          fontWeight: FontWeight.bold),
                    ),
                  ],
                ],
              );
            }),
          ],
        ),
      ),
    );
  }

  // ── Concejal ──────────────────────────────────────────────────────────────

  Widget _buildConcejal() {
    const double chipW  = 130;
    const double totW   = 100;
    const double prefW  = 48;
    const double gap    = 12;
    const double prefGap = 4;

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('CONCEJAL',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A237E),
                    letterSpacing: 0.5)),
            const SizedBox(height: 10),

            // Header de preferencias
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const SizedBox(width: chipW + gap + totW + gap),
                  ...List.generate(12, (i) => Container(
                    width: prefW,
                    margin: EdgeInsets.only(right: i < 11 ? prefGap : 0),
                    alignment: Alignment.center,
                    child: Text('${i + 1}',
                        style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.black45)),
                  )),
                ],
              ),
            ),
            const SizedBox(height: 4),

            // Filas
            ..._kListasCon.asMap().entries.map((e) {
              final li     = e.key;
              final l      = e.value;
              final isLast = li == _kListasCon.length - 1;

              void onTotalNext() {
                if (!l.pref) {
                  if (!isLast) _focusAt(_iConTotal(li + 1));
                  return;
                }
                final total = int.tryParse(_conTotalCtrl[l.codigo]!.text) ?? 0;
                if (total == 0) {
                  if (!isLast) _focusAt(_iConTotal(li + 1));
                } else {
                  _focusAt(_iConPref(li, 0));
                }
              }

              _setupKeyNav(_iConTotal(li), onTotalNext);

              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _ListaChip(lista: l, width: chipW),
                      const SizedBox(width: gap),
                      SizedBox(
                        width: totW,
                        child: _NumField(
                          label: 'Total',
                          ctrl: _conTotalCtrl[l.codigo]!,
                          focusNode: _foci[_iConTotal(li)],
                          onNext: onTotalNext,
                          bold: true,
                          color: l.color,
                        ),
                      ),
                      const SizedBox(width: gap),
                      if (l.pref) ...[
                        ...(_conPrefCtrl[l.codigo]!.asMap().entries.map((pe) {
                          final pi      = pe.key;
                          final isLastP = pi == 11;
                          final onPrefNext = isLastP
                              ? () { if (!isLast) _focusAt(_iConTotal(li + 1)); }
                              : () => _focusAt(_iConPref(li, pi + 1));
                          _setupKeyNav(_iConPref(li, pi), onPrefNext);
                          return Container(
                            width: prefW,
                            margin: EdgeInsets.only(right: isLastP ? 0 : prefGap),
                            child: _NumField(
                              label: '',
                              ctrl: pe.value,
                              focusNode: _foci[_iConPref(li, pi)],
                              onNext: onPrefNext,
                              small: true,
                            ),
                          );
                        })),
                        // Indicador Σ
                        Builder(builder: (_) {
                          final total = int.tryParse(_conTotalCtrl[l.codigo]!.text) ?? 0;
                          final suma  = _sumPrefs(l.codigo);
                          final over  = total > 0 && suma > total;
                          return Container(
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                            decoration: BoxDecoration(
                              color: over ? Colors.red[100] : Colors.grey[100],
                              borderRadius: BorderRadius.circular(5),
                              border: Border.all(
                                color: over ? Colors.red[400]! : Colors.grey[300]!,
                              ),
                            ),
                            child: Text(
                              'Σ $suma',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: over ? Colors.red[700] : Colors.grey[500],
                              ),
                            ),
                          );
                        }),
                      ],
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

// ── Widgets helpers ──────────────────────────────────────────────────────────

class _ListaChip extends StatelessWidget {
  final _Lista lista;
  final double width;
  const _ListaChip({required this.lista, required this.width});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: lista.color,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        lista.label,
        textAlign: TextAlign.center,
        style: TextStyle(
            color: lista.fg, fontWeight: FontWeight.bold, fontSize: 12),
      ),
    );
  }
}

class _TotalChip extends StatelessWidget {
  final String label;
  final int    valor;
  final Color  color;
  const _TotalChip({required this.label, required this.valor, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withAlpha(120)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label: ',
              style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w500)),
          Text('$valor',
              style: TextStyle(fontSize: 14, color: color, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

class _NumField extends StatelessWidget {
  final String                label;
  final TextEditingController ctrl;
  final FocusNode             focusNode;
  final VoidCallback          onNext;
  final bool                  bold;
  final bool                  small;
  final bool                  autofocus;
  final bool                  loading;
  final Color?                color;

  const _NumField({
    required this.label,
    required this.ctrl,
    required this.focusNode,
    required this.onNext,
    this.bold      = false,
    this.small     = false,
    this.autofocus = false,
    this.loading   = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final accent = color ?? const Color(0xFF1A237E);
    return TextField(
      controller:  ctrl,
      focusNode:   focusNode,
      autofocus:   autofocus,
      keyboardType: TextInputType.number,
      textAlign:   TextAlign.center,
      style: TextStyle(
        fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        fontSize:   small ? 13 : 14,
        color:      bold && color != null ? accent : null,
      ),
      decoration: InputDecoration(
        labelText:      label.isEmpty ? null : label,
        isDense:        true,
        border:         const OutlineInputBorder(),
        focusedBorder:  OutlineInputBorder(
          borderSide: BorderSide(color: accent, width: 2),
        ),
        contentPadding: EdgeInsets.symmetric(
            horizontal: small ? 4 : 8, vertical: small ? 6 : 9),
        suffixIcon: loading
            ? const Padding(
                padding: EdgeInsets.all(10),
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : null,
      ),
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      onTap: () => ctrl.selection =
          TextSelection(baseOffset: 0, extentOffset: ctrl.text.length),
      onSubmitted: (_) => onNext(),
    );
  }
}
