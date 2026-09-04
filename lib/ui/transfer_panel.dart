import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../cubit/transfer_cubit.dart';
import '../models/transfer.dart';
import 'format.dart';

/// Bottom queue panel. Deliberately minimal per spec: plain text rows with a
/// numeric percentage — no progress bars, spinners, or animation — so CPU/USB
/// bandwidth goes to the transfers, not rendering. Hidden when empty.
class TransferPanel extends StatelessWidget {
  const TransferPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TransferCubit, TransferQueueState>(
      builder: (context, state) {
        final transfers = state.transfers;
        if (transfers.isEmpty) return const SizedBox.shrink();
        final anyFinished = transfers.any((t) => !t.isActive);
        return Container(
          constraints: const BoxConstraints(maxHeight: 200),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
            color: Theme.of(context).colorScheme.surfaceContainerLow,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
                child: Row(
                  children: [
                    Text('Transfers (${transfers.length})',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    if (anyFinished)
                      TextButton(
                        onPressed: () =>
                            context.read<TransferCubit>().clearFinished(),
                        child: const Text('Clear'),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: transfers.length,
                  itemBuilder: (context, i) => _TransferRow(transfer: transfers[i]),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TransferRow extends StatelessWidget {
  final Transfer transfer;
  const _TransferRow({required this.transfer});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final push = transfer.direction == TransferDirection.push;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Row(
        children: [
          Icon(push ? Icons.arrow_forward : Icons.arrow_back,
              size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(transfer.name,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 12),
          _statusText(context),
          _action(context),
        ],
      ),
    );
  }

  Widget _statusText(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final baseStyle = TextStyle(
        fontSize: 12,
        fontFeatures: const [],
        color: scheme.onSurfaceVariant);
    switch (transfer.status) {
      case TransferStatus.running:
        final speed = transfer.speedBps > 0
            ? '  ${formatBytes(transfer.speedBps)}/s'
            : '';
        return Text('${transfer.percent}%$speed',
            style: baseStyle.copyWith(
                color: scheme.primary, fontWeight: FontWeight.w600));
      case TransferStatus.queued:
        return Text('Queued', style: baseStyle);
      case TransferStatus.done:
        return Text('100%  ${formatBytes(transfer.sizeBytes)}', style: baseStyle);
      case TransferStatus.failed:
        return SizedBox(
          width: 160,
          child: Text(transfer.error ?? 'Failed',
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: baseStyle.copyWith(color: scheme.error)),
        );
      case TransferStatus.cancelled:
        return Text('Cancelled', style: baseStyle);
    }
  }

  Widget _action(BuildContext context) {
    if (transfer.isActive) {
      return IconButton(
        iconSize: 16,
        visualDensity: VisualDensity.compact,
        tooltip: 'Cancel',
        onPressed: () => context.read<TransferCubit>().cancel(transfer.id),
        icon: const Icon(Icons.close),
      );
    }
    final done = transfer.status == TransferStatus.done;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Icon(
        done ? Icons.check : Icons.error_outline,
        size: 16,
        color: done ? Colors.green.shade600 : Theme.of(context).colorScheme.error,
      ),
    );
  }
}
