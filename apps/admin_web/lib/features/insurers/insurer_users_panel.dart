import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import '../shared/form_dialog.dart';
import '../shared/page_parts.dart';
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
    final me = ref.watch(currentUserIdProvider);

    // By name only. Sorting the switched-off to the bottom moved a row out
    // from under the pointer the moment its switch was flipped.
    final sorted = members == null
        ? null
        : (members.toList()..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          ));

    return ListCard(
      title: 'Personas con acceso',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (sorted != null && sorted.isNotEmpty)
            Text(
              sorted.length == 1 ? '1 persona' : '${sorted.length} personas',
              style: text.bodySmall?.copyWith(color: palette.textMuted),
            ),
          if (canEdit) ...[
            const SizedBox(width: Insets.md),
            ElevatedButton.icon(
              key: const Key('add-insurer-user'),
              onPressed: () => showDialog<void>(
                context: context,
                // A tap outside closes an untouched form and asks before
                // throwing away a filled-in one; see [FormDialogScope].
                builder: (_) => _AddUserDialog(insurerId: insurerId),
              ),
              style: ElevatedButton.styleFrom(minimumSize: const Size(0, 40)),
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Agregar usuario'),
            ),
          ],
        ],
      ),
      children: [
        if (sorted == null)
          const Padding(
            padding: EdgeInsets.all(Insets.xl),
            child: BrandLoader(),
          )
        else if (sorted.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: Insets.lg),
            child: EmptyState(
              icon: Icons.group_outlined,
              title: 'Todavía no hay usuarios',
              message:
                  'Agrega a la primera persona que va a pedir grúas por esta '
                  'aseguradora.',
            ),
          )
        else
          for (final m in sorted)
            _MemberRow(
              member: m,
              isMe: m.uid == me,
              canEdit: canEdit,
              onRole: (role) => _change(context, ref, m, role: role),
              onActive: (active) => _change(context, ref, m, active: active),
            ),
      ],
    );
  }
}

/// One person: who they are, what they can do, and whether they can sign in.
class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.isMe,
    required this.canEdit,
    required this.onRole,
    required this.onActive,
  });

  final InsurerMember member;
  final bool isMe;
  final bool canEdit;
  final ValueChanged<InsurerRole> onRole;
  final ValueChanged<bool> onActive;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final m = member;
    final manager = m.role == InsurerRole.manager;
    final initials = [
      for (final part in m.name.trim().split(RegExp(r'\s+')).take(2))
        if (part.isNotEmpty) part[0].toUpperCase(),
    ].join();

    return Padding(
      key: Key('insurer-user-${m.uid}'),
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.lg,
        vertical: Insets.md,
      ),
      child: Opacity(
        // Switched off: still listed, so it can be switched back on, but
        // plainly not one of the people who can act today.
        opacity: m.active ? 1 : 0.6,
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: m.active
                  ? palette.brandTint
                  : palette.surfaceSubtle,
              child: Text(
                initials.isEmpty ? '?' : initials,
                style: text.labelLarge?.copyWith(
                  color: m.active ? palette.brand : palette.textMuted,
                ),
              ),
            ),
            const SizedBox(width: Insets.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          m.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleSmall,
                        ),
                      ),
                      if (isMe) ...[
                        const SizedBox(width: Insets.sm),
                        _Pill(
                          key: Key('insurer-user-self-${m.uid}'),
                          label: 'Tú',
                          color: palette.info,
                        ),
                      ],
                    ],
                  ),
                  Text(
                    m.email,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(color: palette.textMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Insets.md),
            if (!m.active) ...[
              _Pill(label: 'Desactivado', color: palette.textMuted),
              const SizedBox(width: Insets.sm),
            ],
            // What they can do, readable at a glance; for someone who may
            // change it, the same pill opens the choice.
            if (canEdit && !isMe)
              PopupMenuButton<InsurerRole>(
                key: Key('insurer-user-role-${m.uid}'),
                tooltip: 'Cambiar rol',
                onSelected: onRole,
                itemBuilder: (_) => [
                  for (final role in const [
                    InsurerRole.manager,
                    InsurerRole.operator,
                  ])
                    PopupMenuItem(
                      value: role,
                      enabled: role != m.role,
                      child: Text(role.label),
                    ),
                ],
                child: _Pill(
                  label: m.role.label,
                  color: manager ? palette.brand : palette.textMuted,
                  trailing: Icons.expand_more,
                ),
              )
            else
              _Pill(
                label: m.role.label,
                color: manager ? palette.brand : palette.textMuted,
              ),
            // Nobody switches themselves off: the server refuses it, so the
            // control is not offered. The slot stays, so the columns line up.
            SizedBox(
              width: 64,
              child: canEdit && !isMe
                  ? Align(
                      alignment: Alignment.centerRight,
                      child: Switch(
                        key: Key('insurer-user-active-${m.uid}'),
                        value: m.active,
                        onChanged: onActive,
                      ),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// A small tinted label, with an optional arrow when it opens a menu.
class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.color,
    this.trailing,
    super.key,
  });

  final String label;
  final Color color;
  final IconData? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: Corners.brSm,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium
                ?.copyWith(color: color),
          ),
          if (trailing != null) Icon(trailing, size: 16, color: color),
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

  /// Anything typed, or a role other than the one it opens on.
  bool get _dirty =>
      _name.text.trim().isNotEmpty ||
      _email.text.trim().isNotEmpty ||
      _phone.text.trim().isNotEmpty ||
      _role != InsurerRole.operator;

  void _close() => unawaited(
    closeFormDialog(
      context,
      dirty: _dirty,
      submitting: _submitting,
      question: '¿Descartar el usuario?',
      detail: 'Lo que escribiste se pierde y no se crea la cuenta.',
    ),
  );

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

    final palette = context.palette;

    return FormDialogScope(
      onClose: _close,
      child: Dialog(
        backgroundColor: palette.surface,
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(borderRadius: Corners.brLg),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 560,
            maxHeight: MediaQuery.sizeOf(context).height * 0.9,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FormDialogHeader(
                icon: Icons.person_add_alt,
                title: 'Nuevo usuario',
                subtitle: 'Entrará al panel con este correo y una contraseña temporal.',
                onClose: _submitting ? null : _close,
              ),
              FormDialogBody(
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const FormSection('Quién es'),
                      LabeledField(
                        label: 'Nombre completo',
                        required: true,
                        child: TextFormField(
                          key: const Key('user-name'),
                          controller: _name,
                          textCapitalization: TextCapitalization.words,
                          decoration: const InputDecoration(
                            hintText: 'Marta Díaz Rodríguez',
                            prefixIcon: Icon(Icons.person_outline, size: 18),
                          ),
                          validator: (v) => (v ?? '').trim().length < 2
                              ? 'Escribe el nombre.'
                              : null,
                        ),
                      ),
                      LabeledField(
                        // No note under it: the header already says this is what
                        // they sign in with, and a note there sits below the
                        // field's own error, which reads as two answers.
                        label: 'Correo',
                        required: true,
                        child: TextFormField(
                          key: const Key('user-email'),
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(
                            hintText: 'marta@aseguradora.com.do',
                            prefixIcon: Icon(Icons.mail_outline, size: 18),
                          ),
                          validator: DoValidators.email,
                        ),
                      ),
                      LabeledField(
                        label: 'Teléfono',
                        child: TextFormField(
                          key: const Key('user-phone'),
                          controller: _phone,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(
                            hintText: '809 555-0150',
                            prefixIcon: Icon(Icons.phone_outlined, size: 18),
                          ),
                          // Optional, but a number half typed in is worse than
                          // none: nobody calls it and nobody knows it is wrong.
                          validator: (v) => (v ?? '').trim().isEmpty
                              ? null
                              : DoValidators.phone(v),
                        ),
                      ),
                      const SizedBox(height: Insets.sm),
                      const FormSection(
                        'Qué puede hacer',
                        note: 'Se cambia después desde esta misma lista.',
                      ),
                      // Two cards rather than a dropdown: the choice is what the
                      // person will be able to do, and the dropdown cut the
                      // manager's line off mid-sentence.
                      // Not `InsurerRole.values`: `unknown` is what a record
                      // from a newer build decodes to, never something to hand
                      // somebody.
                      for (final role in const [
                        InsurerRole.operator,
                        InsurerRole.manager,
                      ])
                        _RoleChoice(
                          role: role,
                          selected: _role == role,
                          onSelect: () => setState(() => _role = role),
                        ),
                      if (_error != null) ...[
                        const SizedBox(height: Insets.sm),
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
                note: '* Obligatorio',
                label: 'Crear usuario',
                onCancel: _close,
                onSubmit: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One role, with what it lets the person do, picked by tapping the card.
class _RoleChoice extends StatelessWidget {
  const _RoleChoice({
    required this.role,
    required this.selected,
    required this.onSelect,
  });

  final InsurerRole role;
  final bool selected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final (title, detail, icon) = switch (role) {
      InsurerRole.operator => (
        'Operador',
        'Pide grúas y sigue sus servicios.',
        Icons.support_agent_outlined,
      ),
      _ => (
        'Administrador',
        'Además maneja los usuarios y ve las facturas.',
        Icons.admin_panel_settings_outlined,
      ),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.sm),
      child: InkWell(
        key: Key('user-role-${role.name}'),
        onTap: onSelect,
        borderRadius: Corners.brMd,
        child: Container(
          padding: const EdgeInsets.all(Insets.md),
          decoration: BoxDecoration(
            color: selected ? palette.brandTint : palette.surface,
            borderRadius: Corners.brMd,
            border: Border.all(
              color: selected ? palette.brand : palette.border,
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: selected ? palette.brand : palette.textMuted,
              ),
              const SizedBox(width: Insets.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: text.titleSmall),
                    Text(
                      detail,
                      style: text.bodySmall?.copyWith(color: palette.textMuted),
                    ),
                  ],
                ),
              ),
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 20,
                color: selected ? palette.brand : palette.textFaint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The first password, shown once, with a copy button.
///
/// The same shell as the form it follows, rather than a bare alert: this is
/// the second half of one job, and the only moment this password exists on a
/// screen.
class _PasswordShown extends StatelessWidget {
  const _PasswordShown({required this.user, required this.email});

  final NewInsurerUser user;
  final String email;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;

    return Dialog(
      backgroundColor: palette.surface,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(borderRadius: Corners.brLg),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FormDialogHeader(
              icon: Icons.check_circle_outline,
              title: 'Usuario creado',
              subtitle: email,
              onClose: () => Navigator.of(context).pop(),
            ),
            Padding(
              padding: const EdgeInsets.all(Insets.xxl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const FieldLabel('Contraseña temporal'),
                  const SizedBox(height: Insets.sm),
                  // Boxed and spaced out: this gets read aloud over the phone
                  // or copied by hand, and a password set in running text is
                  // where l becomes 1 and O becomes 0.
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Insets.lg,
                      vertical: Insets.md,
                    ),
                    decoration: BoxDecoration(
                      color: palette.surfaceSubtle,
                      borderRadius: Corners.brMd,
                      border: Border.all(color: palette.border),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: SelectableText(
                            user.temporaryPassword,
                            key: const Key('temporary-password'),
                            style: text.titleLarge?.copyWith(
                              letterSpacing: 1.4,
                              fontFeatures: const [
                                FontFeature.slashedZero(),
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: user.temporaryPassword),
                            );
                            if (context.mounted) {
                              showToast(context, 'Contraseña copiada');
                            }
                          },
                          tooltip: 'Copiar',
                          icon: const Icon(Icons.copy, size: 18),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Insets.lg),
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
            FormDialogFooter(
              submitting: false,
              note: 'Se la entregas tú, por donde ustedes hablen.',
              label: 'Listo',
              submitKey: const Key('password-done'),
              onCancel: null,
              onSubmit: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}
