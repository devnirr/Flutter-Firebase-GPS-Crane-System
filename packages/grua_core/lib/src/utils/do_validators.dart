import 'package:flutter/services.dart';

/// Dominican identity checks shared by every form that collects them.
///
/// The admin panel's "Nuevo chofer" form and the driver app's self-registration
/// ask for the same papers, and the server re-runs the cédula check on both
/// paths. Keeping one copy here means a typo is refused identically everywhere,
/// and before an Auth account is ever created for it.
abstract final class DoValidators {
  /// Dominican numbers are +1 with one of these area codes.
  static const areaCodes = {'809', '829', '849'};

  static String digits(String? value) =>
      (value ?? '').replaceAll(RegExp(r'\D'), '');

  /// 11 digits with the JCE's alternating 1/2 check digit.
  static String? cedula(String? value) {
    final d = digits(value);
    if (d.isEmpty) return 'Escribe la cédula.';
    if (d.length != 11) return 'La cédula tiene 11 dígitos.';

    var sum = 0;
    for (var i = 0; i < 10; i++) {
      var product = int.parse(d[i]) * (i.isEven ? 1 : 2);
      if (product > 9) product -= 9;
      sum += product;
    }
    if ((10 - (sum % 10)) % 10 != int.parse(d[10])) {
      return 'Esa cédula no es válida.';
    }
    return null;
  }

  static String? phone(String? value) {
    final d = digits(value);
    if (d.isEmpty) return 'Escribe el teléfono.';
    if (d.length != 10) return 'El teléfono tiene 10 dígitos.';
    if (!areaCodes.contains(d.substring(0, 3))) {
      return 'Usa un área 809, 829 o 849.';
    }
    return null;
  }

  /// A stored phone as it is written down here: `809 555-0150`.
  ///
  /// Numbers are stored E.164 (`+18095550150`), which is right for dialling
  /// and unreadable on a page. Anything that is not a Dominican ten-digit
  /// number is handed back untouched rather than mangled into a shape it is
  /// not.
  static String phoneLabel(String? value) {
    final raw = (value ?? '').trim();
    var d = digits(raw);
    if (d.length == 11 && d.startsWith('1')) d = d.substring(1);
    if (d.length != 10 || !areaCodes.contains(d.substring(0, 3))) return raw;
    return '${d.substring(0, 3)} ${d.substring(3, 6)}-${d.substring(6)}';
  }

  /// Optional: 9 digits for a company, 11 for a persona física.
  static String? rnc(String? value) {
    final d = digits(value);
    if (d.isEmpty) return null;
    if (d.length != 9 && d.length != 11) return 'El RNC tiene 9 u 11 dígitos.';
    return null;
  }

  /// Required: a company's 9-digit RNC with a correct DGII check digit.
  /// Mirrors `isValidCompanyRnc` in the functions, which is the authority.
  static String? companyRnc(String? value) {
    final d = digits(value);
    if (d.isEmpty) return 'Escribe el RNC.';
    if (d.length != 9) return 'El RNC de una empresa tiene 9 dígitos.';
    const weights = [7, 9, 8, 6, 5, 4, 3, 2];
    var sum = 0;
    for (var i = 0; i < 8; i++) {
      sum += int.parse(d[i]) * weights[i];
    }
    final remainder = sum % 11;
    final check = remainder == 0
        ? 2
        : remainder == 1
            ? 1
            : 11 - remainder;
    if (check != int.parse(d[8])) return 'Ese RNC no es válido. Revísalo.';
    return null;
  }

  /// A plate as it is keyed and compared: uppercase, no spaces or dashes.
  /// Mirrors `normalizePlate` in the functions, which is the authority.
  static String plateKey(String? value) =>
      (value ?? '').toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');

  /// One or two series letters and five or six digits: `L123456`, `EX12345`.
  static String? plate(String? value) {
    final key = plateKey(value);
    if (key.isEmpty) return 'Escribe la placa.';
    if (!RegExp(r'^[A-Z]{1,2}\d{5,6}$').hasMatch(key)) {
      return 'Esa placa no es válida. Ejemplo: L123456.';
    }
    return null;
  }

  static String? email(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return 'Escribe un correo.';
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]{2,}$').hasMatch(v)) {
      return 'Ese correo no es válido.';
    }
    return null;
  }
}

/// Types a cédula as `001-1234567-8` while the user enters bare digits.
class CedulaInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = DoValidators.digits(newValue.text);
    final capped = digits.length > 11 ? digits.substring(0, 11) : digits;

    final buffer = StringBuffer();
    for (var i = 0; i < capped.length; i++) {
      if (i == 3 || i == 10) buffer.write('-');
      buffer.write(capped[i]);
    }
    final text = buffer.toString();

    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// Types a company's RNC as the DGII prints it, `1-30-00000-1`, while the user
/// enters bare digits. Eleven digits — a persona física billing under a cédula
/// — are left as typed, since that number is grouped differently.
class RncInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = DoValidators.digits(newValue.text);
    final capped = digits.length > 11 ? digits.substring(0, 11) : digits;

    final buffer = StringBuffer();
    for (var i = 0; i < capped.length; i++) {
      if (capped.length <= 9 && (i == 1 || i == 3 || i == 8)) buffer.write('-');
      buffer.write(capped[i]);
    }
    final text = buffer.toString();

    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// Types a Dominican number as `(809) 555-1234`.
class DoPhoneInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var digits = DoValidators.digits(newValue.text);
    // Pasting a number with the country code should not shift everything by one.
    if (digits.length == 11 && digits.startsWith('1')) {
      digits = digits.substring(1);
    }
    final capped = digits.length > 10 ? digits.substring(0, 10) : digits;

    final buffer = StringBuffer();
    for (var i = 0; i < capped.length; i++) {
      if (i == 0) buffer.write('(');
      if (i == 3) buffer.write(') ');
      if (i == 6) buffer.write('-');
      buffer.write(capped[i]);
    }
    final text = buffer.toString();

    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
