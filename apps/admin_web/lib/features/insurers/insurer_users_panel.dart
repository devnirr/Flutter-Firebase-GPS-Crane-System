import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import '../shared/form_dialog.dart';
import '../shared/toast.dart';

/// A company's people: who they are, their role, whether they may sign in.
class InsurerUsersPanel extends ConsumerWidget {
  const InsurerUsersPanel({
    required this.insurerId,
    this.canEdit = true,
    super.key,
  });

  final String insurerId;

  /// Only the office admin (or the company's own manager) changes people.
  final bool canEdit;

  Future<void> _change(
    BuildContext context,
    WidgetRef ref,
    InsurerMember member, {
    InsurerRole? role,
    bool? active,
  }) async {
    final result = await ref
        .read(functionsGatewayProvider)
        .updateInsurerUser(
          insurerId: insurerId,
          uid: member.uid,
          role: role,
          active: active,
        );
    if (!context.mounted) return;
    final (message, tone) = switch (result) {
      Ok() => (
        active == null
            ? '${member.name} ahora es ${role!.label.toLowerCase()}.'
            : active
            ? '${member.name} puede volver a entrar.'
            : '${member.name} ya no puede entrar.',
        ToastTone.success,
      ),
      Err(:final failure) => (failure.userMessage, ToastTone.error),
    };
    showToast(context, message, tone: tone);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final members = ref.watch(insurerMembersProvider(insurerId)).value;

    return FloatingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('Usuarios', style: text.titleMedium)),
              if (canEdit)
                ElevatedButton.icon(
                  key: const Key('add-insurer-user'),
                  onPressed: () => showDialog<void>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => _AddUserDialog(insurerId: insurerId),
                  ),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(0, 40),
                  ),
                  icon: const Icon(Icons.person_add_alt),
                  label: const Text('Agregar usuario'),
                ),
            ],
          ),
          const SizedBox(height: Insets.md),
          if (members == null)
            const BrandLoader()
          else if (members.isEmpty)
            Text(
              'Esta aseguradora todavía no tiene usuarios.',
              style: text.bodyMedium?.copyWith(color: palette.textMuted),
            )
          else
            for (final m in members)
              ListTile(
                key: Key('insurer-user-${m.uid}'),
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  backgroundColor: m.active
                      ? palette.brandTint
                      : palette.surfaceSubtle,
                  child: Text(m.name.isEmpty ? '?' : m.name[0]),
                ),
                title: Text(m.name),
                subtitle: Text(
                  [
                    m.email,
                    m.role.label,
                    if (!m.active) 'Desactivado',
                  ].join(' · '),
                ),
                // Nobody demotes or switches off themselves: the server
                // refuses it, so the controls are not offered.
                trailing: !canEdit
                    ? null
                    : m.uid == ref.watch(currentUserIdProvider)
                    ? Text(
                        'Tú',
                        key: Key('insurer-user-self-${m.uid}'),
                        style: text.bodySmall?.copyWith(color: palette.textMuted),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PopupMenuButton<InsurerRole>(
                            key: Key('insurer-user-role-${m.uid}'),
                            tooltip: 'Cambiar rol',
                            onSelected: (role) =>
                                _change(context, ref, m, role: role),
                            itemBuilder: (_) => [
                              for (final role in [
                                InsurerRole.manager,
                                InsurerRole.operator,
                              ])
                                PopupMenuItem(
                                  value: role,
                                  enabled: role != m.role,
                                  child: Text(role.label),
                                ),
                            ],
                            icon: const Icon(Icons.manage_accounts_outlined),
                          ),
                          Switch(
                            key: Key('insurer-user-active-${m.uid}'),
                            value: m.active,
                            onChanged: (active) =>
                                _change(context, ref, m, active: active),
                          ),
                        ],
                      ),
              ),
        ],
      ),
    );
  }
}

class _AddUserDialog extends ConsumerStatefulWidget {
  const _AddUserDialog({required this.insurerId});

  final String insurerId;

  @override
  ConsumerState<_AddUserDialog> createState() => _AddUserDialogState();
}

class _AddUserDialogState extends ConsumerState<_AddUserDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  InsurerRole _role = InsurerRole.operator;
  var _submitting = false;
  String? _error;
  NewInsurerUser? _created;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final result = await ref
        .read(functionsGatewayProvider)
        .createInsurerUser(
          insurerId: widget.insurerId,
          name: _name.text.trim(),
          email: _email.text.trim(),
          phone: _phone.text.trim(),
          role: _role,
        );
    if (!mounted) return;
    setState(() {
      _submitting = false;
      switch (result) {
        case Ok(:final value):
          _created = value;
        case Err(:final failure):
          _error = failure.userMessage;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final created = _created;
    if (created != null) {
      return _PasswordShown(user: created, email: _email.text.trim());
    }

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FormDialogHeader(
              title: 'Nuevo usuario',
              subtitle:
                  'Entrará al panel con este correo y una contraseña temporal.',
              onClose: _submitting ? null : () => Navigator.of(context).pop(),
            ),
            Padding(
              padding: const EdgeInsets.all(Insets.xxl),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      key: const Key('user-name'),
                      controller: _name,
                      decoration: const InputDecoration(
                        labelText: 'Nombre completo',
                      ),
                      validator: (v) => (v ?? '').trim().length < 2
                          ? 'Escribe el nombre.'
                          : null,
                    ),
                    const SizedBox(height: Insets.md),
                    TextFormField(
                      key: const Key('user-email'),
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(labelText: 'Correo'),
                      validator: DoValidators.email,
                    ),
                    const SizedBox(height: Insets.md),
                    TextFormField(
                      key: const Key('user-phone'),
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Teléfono (opcional)',
                      ),
                    ),
                    const SizedBox(height: Insets.md),
                    DropdownButtonFormField<InsurerRole>(
                      key: const Key('user-role'),
                      isExpanded: true,
                      initialValue: _role,
                      decoration: const InputDecoration(labelText: 'Rol'),
                      items: const [
                        DropdownMenuItem(
                          value: InsurerRole.operator,
                          child: Text(
                            'Operador: pide y sigue grúas',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        DropdownMenuItem(
                          value: InsurerRole.manager,
                          child: Text(
                            'Administrador: además maneja usuarios y facturas',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                      onChanged: (role) =>
                          setState(() => _role = role ?? _role),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: Insets.lg),
                      InlineNotice(
                        key: const Key('user-error'),
                        tone: NoticeTone.error,
                        icon: Icons.error_outline,
                        message: _error!,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            FormDialogFooter(
              submitting: _submitting,
              label: 'Crear usuario',
              onCancel: () => Navigator.of(context).pop(),
              onSubmit: _submit,
            ),
          ],
        ),
      ),
    );
  }
}

/// The first password, shown once, with a copy button.
class _PasswordShown extends StatelessWidget {
  const _PasswordShown({required this.user, required this.email});

  final NewInsurerUser user;
  final String email;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('Usuario creado'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Correo: $email'),
            const SizedBox(height: Insets.md),
            const FieldLabel('Contraseña temporal'),
            SelectableText(
              user.temporaryPassword,
              key: const Key('temporary-password'),
              style: text.titleLarge,
            ),
            const SizedBox(height: Insets.md),
            const InlineNotice(
              tone: NoticeTone.warning,
              icon: Icons.lock_outline,
              message:
                  'Anótala ahora: no se vuelve a mostrar. Se le pedirá '
                  'cambiarla al entrar por primera vez.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () =>
              Clipboard.setData(ClipboardData(text: user.temporaryPassword)),
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copiar'),
        ),
        ElevatedButton(
          key: const Key('password-done'),
          onPressed: () => Navigator.of(context).pop(),
          style: ElevatedButton.styleFrom(minimumSize: const Size(0, 40)),
          child: const Text('Listo'),
        ),
      ],
    );
  }
}
