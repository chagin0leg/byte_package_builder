import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

// --- Data Persistence Service ---
class ConfigService {
  static const _configKey = 'byte_package_config';

  Future<Map<String, dynamic>> _read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final content = prefs.getString(_configKey);
      return content != null ? json.decode(content) : {};
    } catch (e) {
      debugPrint('Error reading config: $e');
    }
    return {};
  }

  Future<void> _write(Map<String, dynamic> data) async {
    final content = const JsonEncoder.withIndent('  ').convert(data);
    try {
      (await SharedPreferences.getInstance()).setString(_configKey, content);
    } catch (e) {
      debugPrint('Error writing config: $e');
    }
  }

  Future<List<Map<String, String>>> getLastSession() async {
    final config = await _read();
    final session = config['__last_session__'];
    return session is List
        ? session.map((item) => Map<String, String>.from(item)).toList()
        : [];
  }

  Future<String?> getLastSelectedPreset() async =>
      (await _read())['last_selected_preset'];

  Future<void> saveSession(List<RowData> rows, String? selectedPreset) async {
    final config = await _read();
    config['__last_session__'] = rows
        .map((r) => {
              'value': r.valueController.text,
              'description': r.descriptionController.text
            })
        .toList();
    if (selectedPreset != null) {
      config['last_selected_preset'] = selectedPreset;
    }
    await _write(config);
  }

  Future<List<String>> getPresetNames() async {
    final config = await _read();
    final presets = config['presets'];
    return presets is Map ? (List<String>.from(presets.keys)..sort()) : [];
  }

  Future<List<Map<String, String>>> loadPreset(String name) async {
    final config = await _read();
    final presetData = config['presets']?[name];
    return presetData is List
        ? presetData.map((item) => Map<String, String>.from(item)).toList()
        : [];
  }

  Future<void> savePreset(String name, List<RowData> rows) async {
    final config = await _read();
    config['presets'] ??= <String, dynamic>{};
    config['presets'][name] = rows
        .map((r) => {
              'value': r.valueController.text,
              'description': r.descriptionController.text
            })
        .toList();
    await _write(config);
  }

  Future<void> deletePreset(String name) async {
    final config = await _read();
    (config['presets'] as Map?)?.remove(name);
    await _write(config);
  }
}

class Crc8 {
  static const int _polynomial = 0x07;
  int convert(List<int> data) => data.fold(0, (crc, byte) {
        crc ^= byte;
        for (int i = 0; i < 8; i++) {
          crc = (crc & 0x80) != 0 ? ((crc << 1) ^ _polynomial) : (crc << 1);
          crc &= 0xFF;
        }
        return crc;
      });
}

// --- Main Application Entry Point ---
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BytePackageBuilderApp());
}

// --- Data Model for a Row ---
class RowData {
  final TextEditingController valueController;
  final TextEditingController descriptionController;
  final FocusNode valueFocusNode;
  bool isValueInvalid = false;

  RowData({String value = '', String description = ''})
      : valueController = TextEditingController(text: value),
        descriptionController = TextEditingController(text: description),
        valueFocusNode = FocusNode();

  void dispose() {
    valueController.dispose();
    descriptionController.dispose();
    valueFocusNode.dispose();
  }
}

// --- Root Application Widget ---
class BytePackageBuilderApp extends StatelessWidget {
  const BytePackageBuilderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Byte Package Builder',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const BytePackageBuilderPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// --- Main Page Widget ---
class BytePackageBuilderPage extends StatefulWidget {
  const BytePackageBuilderPage({super.key});

  @override
  State<BytePackageBuilderPage> createState() => _BytePackageBuilderPageState();
}

class _BytePackageBuilderPageState extends State<BytePackageBuilderPage> {
  final _configService = ConfigService();
  final List<RowData> _rows = [];
  String _checksumValue = "00";
  final TextEditingController _checksumController = TextEditingController();
  final String _startByte = "AA";

  List<String> _presets = [];
  String? _selectedPreset;

  @override
  void initState() {
    super.initState();
    _checksumController.text = _checksumValue;
    _loadData().then((_) => _updateChecksum());

    // Add listener to each row's value controller for validation
    for (var row in _rows) {
      row.valueController.addListener(() => _validateAndFormat(row));
    }
  }

  @override
  void dispose() {
    for (var row in _rows) {
      row.dispose();
    }
    _checksumController.dispose();
    super.dispose();
  }

  // --- Core Logic Methods ---

  void _validateAndFormat(RowData row) {
    const ru = 'фисвуаФИСВУА';
    const en = 'ABCDEFABCDEF';
    final ruToEn = Map.fromIterables(ru.split(''), en.split(''));

    final controller = row.valueController;
    String text = controller.text;
    String convertedText = text.split('').map((c) => ruToEn[c] ?? c).join();
    String validValue = RegExp(r'[^0-9A-Fa-f]', caseSensitive: false)
        .allMatches(convertedText)
        .fold<String>(
          convertedText,
          (String result, Match match) =>
              result.replaceAll(match.group(0)!, ''),
        )
        .toUpperCase();

    if (validValue != controller.text) {
      final selection = controller.selection;
      controller.text = validValue;
      controller.selection = selection.copyWith(
        baseOffset: selection.baseOffset.clamp(0, validValue.length),
        extentOffset: selection.extentOffset.clamp(0, validValue.length),
      );
    }

    final isInvalid = validValue.length % 2 != 0;
    if (row.isValueInvalid != isInvalid) {
      setState(() {
        row.isValueInvalid = isInvalid;
      });
    }

    _updateChecksum();
    _saveData(saveSession: true);
  }

  void _updateChecksum() {
    List<int> bytesToCheck = [];
    for (var row in _rows) {
      String value = row.valueController.text;
      for (int i = 0; i < value.length; i += 2) {
        if (i + 2 <= value.length) {
          try {
            bytesToCheck.add(int.parse(value.substring(i, i + 2), radix: 16));
          } catch (e) {
            // Ignore parse errors, validation should prevent this
          }
        }
      }
    }

    setState(() {
      _checksumValue = Crc8()
          .convert(bytesToCheck)
          .toRadixString(16)
          .toUpperCase()
          .padLeft(2, '0');
      _checksumController.text = _checksumValue;
    });
  }

  void _addRow() {
    setState(() {
      final newRow = RowData();
      newRow.valueController.addListener(() => _validateAndFormat(newRow));
      _rows.add(newRow);
    });
    _saveData(saveSession: true);
  }

  void _deleteRow(int index) {
    setState(() {
      _rows[index].dispose();
      _rows.removeAt(index);
    });
    _updateChecksum();
    _saveData(saveSession: true);
  }

  void _copyToClipboard() async {
    List<String> values = [_startByte];
    for (var row in _rows) {
      String value = row.valueController.text;
      for (int i = 0; i < value.length; i += 2) {
        if (i + 2 <= value.length) {
          values.add(value.substring(i, i + 2));
        }
      }
    }
    values.add(_checksumValue);
    await Clipboard.setData(ClipboardData(text: values.join()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Скопировано в буфер обмена!')));
  }

  void _copyMarkdownTable() async {
    try {
      List<List<String>> byteDescPairs = [];
      byteDescPairs.add([_startByte, 'Стартовый байт']);

      for (var row in _rows) {
        String value = row.valueController.text;
        String desc = row.descriptionController.text.isEmpty
            ? ' '
            : row.descriptionController.text;
        for (int i = 0; i < value.length; i += 2) {
          if (i + 2 <= value.length) {
            byteDescPairs.add([value.substring(i, i + 2), desc]);
          }
        }
      }
      byteDescPairs.add([_checksumValue, 'Контрольная сумма']);

      if (byteDescPairs.isEmpty) return;

      List<Map<String, dynamic>> grouped = [];
      if (byteDescPairs.isNotEmpty) {
        String currentDesc = byteDescPairs.first[1];
        List<String> currentBytes = [];

        for (var pair in byteDescPairs) {
          if (pair[1] != currentDesc && currentBytes.isNotEmpty) {
            grouped.add({'desc': currentDesc, 'bytes': currentBytes});
            currentBytes = [];
          }
          currentDesc = pair[1];
          currentBytes.add(pair[0]);
        }
        grouped.add({'desc': currentDesc, 'bytes': currentBytes});
      }

      int totalBytes = byteDescPairs.length;
      List<String> header = ["|  "] +
          List.generate(totalBytes - 1, (i) => i.toString().padLeft(2, '0')) +
          [" Описание                               |"];
      List<String> separator = ["|--"] +
          List.filled(totalBytes - 1, "--") +
          ["----------------------------------------|"];
      List<String> tableLines = [header.join("|"), separator.join("|")];

      int byteIndex = 0;
      for (var group in grouped) {
        List<String> bytes = group['bytes'];
        String desc = group['desc'];
        List<String> row = List.filled(totalBytes + 1, "  ");

        for (int i = 0; i < bytes.length; i++) {
          if (byteIndex + i < totalBytes) {
            row[byteIndex + i] = bytes[i];
          }
        }
        row[row.length - 1] = " ${desc.padRight(39)}";
        tableLines.add("|${row.join("|")}|");

        byteIndex += bytes.length;
      }

      Clipboard.setData(ClipboardData(text: tableLines.join("\n")));
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Markdown-таблица скопирована!')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ошибка копирования в буфер обмена!')));
    }
  }

  // --- Data Persistence ---

  Future<void> _saveData({bool saveSession = false, String? presetName}) async {
    if (saveSession) {
      await _configService.saveSession(_rows, _selectedPreset);
    }
    if (presetName != null) {
      await _configService.savePreset(presetName, _rows);
      await _updatePresetList();
      setState(() => _selectedPreset = presetName);
    }
  }

  Future<void> _loadData() async {
    final sessionData = await _configService.getLastSession();
    if (sessionData.isNotEmpty) {
      _loadRowsData(sessionData);
    }

    await _updatePresetList();
    final lastPreset = await _configService.getLastSelectedPreset();
    if (lastPreset != null && _presets.contains(lastPreset)) {
      setState(() => _selectedPreset = lastPreset);
    }
  }

  void _loadRowsData(List<Map<String, String>> data) {
    setState(() {
      for (var row in _rows) {
        row.dispose();
      }
      _rows.clear();
      for (var rowData in data) {
        final newRow = RowData(
          value: rowData['value'] ?? '',
          description: rowData['description'] ?? '',
        );
        newRow.valueController.addListener(() => _validateAndFormat(newRow));
        _rows.add(newRow);
        _validateAndFormat(newRow);
      }
      _checksumController.text = _checksumValue;
    });
    _updateChecksum();
  }

  Future<void> _updatePresetList() async {
    _presets = await _configService.getPresetNames();
    setState(() {
      if (!_presets.contains(_selectedPreset)) _selectedPreset = null;
    });
  }

  void _loadSelectedPreset(String? presetName) {
    if (presetName == null) return;
    _configService.loadPreset(presetName).then((data) {
      if (data.isNotEmpty) {
        _loadRowsData(data);
        setState(() => _selectedPreset = presetName);
      }
    });
  }

  Future<void> _savePreset() async {
    final presetName =
        await _showInputDialog("Сохранить пресет", "Введите имя пресета:");
    if (presetName != null && presetName.isNotEmpty) {
      await _saveData(presetName: presetName);
    }
  }

  Future<void> _deletePreset() async {
    if (_selectedPreset == null) return;

    final confirm = await _showConfirmDialog("Удалить пресет",
        "Вы уверены, что хотите удалить пресет '$_selectedPreset'?");

    if (confirm == true) {
      await _configService.deletePreset(_selectedPreset!);
      await _updatePresetList();
    }
  }

  // --- UI Builder Methods ---

  static const _inputDecoration = InputDecoration(
    border: OutlineInputBorder(),
    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
  );

  static final _readOnlyInputDecoration = _inputDecoration.copyWith(
    filled: true,
    fillColor: const Color.fromARGB(255, 238, 238, 238),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Byte Package Builder'),
        backgroundColor: Colors.blueGrey[800],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          spacing: 8,
          children: [
            _buildHeader(),
            Expanded(child: _buildRowsList()),
            _buildControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return const Row(
      children: [
        Expanded(
          flex: 2,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8.0),
            child:
                Text('Значение', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
        Expanded(
          flex: 5,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8.0),
            child:
                Text('Описание', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
        SizedBox(width: 48), // For delete button alignment
      ],
    );
  }

  Widget _buildRowsList() {
    return ListView(
      children: [
        _buildRow(
            value: _startByte,
            description: 'Стартовый байт',
            isEditable: false),
        ..._rows.asMap().entries.map((entry) {
          int index = entry.key;
          RowData row = entry.value;
          return _buildRow(
              data: row, isEditable: true, onDelete: () => _deleteRow(index));
        }),
        _buildRow(
            value: _checksumValue,
            description: 'Контрольная сумма',
            isEditable: false,
            controller: _checksumController),
      ],
    );
  }

  Widget _buildRow({
    RowData? data,
    String? value,
    String? description,
    required bool isEditable,
    VoidCallback? onDelete,
    TextEditingController? controller,
  }) {
    final valueController =
        isEditable ? data!.valueController : TextEditingController(text: value);
    final descController = isEditable
        ? data!.descriptionController
        : TextEditingController(text: description);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Row(
        spacing: 8,
        children: [
          Expanded(
            flex: 2,
            child: TextField(
              controller: controller ?? valueController,
              readOnly: !isEditable,
              focusNode: isEditable ? data!.valueFocusNode : null,
              decoration: isEditable
                  ? _inputDecoration.copyWith(
                      filled: true,
                      fillColor: data!.isValueInvalid
                          ? Colors.pink[100]
                          : Colors.white,
                    )
                  : _readOnlyInputDecoration,
            ),
          ),
          Expanded(
            flex: 5,
            child: TextField(
              controller: descController,
              readOnly: !isEditable,
              decoration:
                  isEditable ? _inputDecoration : _readOnlyInputDecoration,
            ),
          ),
          SizedBox(
            width: 48,
            child: isEditable
                ? IconButton(
                    icon: const Icon(Icons.delete),
                    onPressed: onDelete,
                  )
                : null,
          ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    return Column(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              spacing: 8,
              children: [
                const Text("Пресеты: "),
                Expanded(
                  child: DropdownButton<String>(
                    value: _selectedPreset,
                    hint: const Text("Выбрать..."),
                    isExpanded: true,
                    items:
                        _presets.map<DropdownMenuItem<String>>((String value) {
                      return DropdownMenuItem<String>(
                        value: value,
                        child: Text(value),
                      );
                    }).toList(),
                    onChanged: (value) => _loadSelectedPreset(value),
                  ),
                ),
                ElevatedButton(
                  onPressed: _savePreset,
                  child: const Text('Сохранить'),
                ),
                ElevatedButton(
                  onPressed: _selectedPreset == null ? null : _deletePreset,
                  child: const Text('Удалить'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 16,
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Добавить строку'),
              onPressed: _addRow,
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Копировать'),
              onPressed: _copyToClipboard,
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.table_chart),
              label: const Text('Копировать в Markdown'),
              onPressed: _copyMarkdownTable,
            ),
          ],
        ),
      ],
    );
  }

  // --- Dialog Helpers ---
  Future<String?> _showInputDialog(String title, String label) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (cntx) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: ctrl,
            decoration: InputDecoration(labelText: label),
            autofocus: true,
          ),
          actions: [
            for (bool i in [false, true])
              TextButton(
                child: Text(i ? 'ОК' : 'Отмена'),
                onPressed: () => Navigator.of(cntx).pop(i ? ctrl.text : null),
              ),
          ],
        );
      },
    );
  }

  Future<bool?> _showConfirmDialog(String title, String content) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          for (bool i in [false, true])
            TextButton(
                child: Text(i ? 'Да' : 'Нет'),
                onPressed: () => Navigator.of(context).pop(i)),
        ],
      ),
    );
  }
}
