import React from 'react';
import TestRenderer, { act } from 'react-test-renderer';
import { Text, TouchableOpacity } from 'react-native';
import ConfirmationDialog from '@/components/wallet/ConfirmationDialog';

// react-test-renderer ships its own nested @types/react — see
// EmptyState.test.tsx (#472) for why this cast is needed.
function render(ui: React.ReactElement) {
  let renderer!: TestRenderer.ReactTestRenderer;
  act(() => {
    renderer = TestRenderer.create(ui as never);
  });
  return renderer;
}

describe('ConfirmationDialog (#471 additions: children, confirmDisabled)', () => {
  it('renders title, message, and both buttons', () => {
    const renderer = render(
      <ConfirmationDialog
        visible
        title="Confirm Payment"
        message="Send 10 XLM?"
        onConfirm={jest.fn()}
        onCancel={jest.fn()}
      />,
    );
    const texts = renderer.root.findAllByType(Text as never).map((n) => n.props.children);
    expect(texts).toContain('Confirm Payment');
    expect(texts).toContain('Send 10 XLM?');
    expect(texts).toContain('Confirm');
    expect(texts).toContain('Cancel');
  });

  it('calls onConfirm when the confirm button is pressed', () => {
    const onConfirm = jest.fn();
    const renderer = render(
      <ConfirmationDialog
        visible
        title="t"
        message="m"
        onConfirm={onConfirm}
        onCancel={jest.fn()}
      />,
    );
    const buttons = renderer.root.findAllByType(TouchableOpacity as never);
    const confirmButton = buttons.find(
      (b) => (b.props as { accessibilityLabel?: string }).accessibilityLabel === 'Confirm',
    )!;
    act(() => {
      (confirmButton.props as { onPress: () => void }).onPress();
    });
    expect(onConfirm).toHaveBeenCalledTimes(1);
  });

  it('renders children between the message and the buttons', () => {
    const renderer = render(
      <ConfirmationDialog visible title="t" message="m" onConfirm={jest.fn()} onCancel={jest.fn()}>
        <Text testID="fee-slot">Network Fee: 0.00001 XLM</Text>
      </ConfirmationDialog>,
    );
    const texts = renderer.root.findAllByType(Text as never).map((n) => n.props.children);
    expect(texts).toContain('Network Fee: 0.00001 XLM');
  });

  it('does not call onConfirm when confirmDisabled is true, even if pressed', () => {
    const onConfirm = jest.fn();
    const renderer = render(
      <ConfirmationDialog
        visible
        title="t"
        message="m"
        onConfirm={onConfirm}
        onCancel={jest.fn()}
        confirmDisabled
      />,
    );
    const buttons = renderer.root.findAllByType(TouchableOpacity as never);
    const confirmButton = buttons.find(
      (b) => (b.props as { accessibilityLabel?: string }).accessibilityLabel === 'Confirm',
    )!;
    expect((confirmButton.props as { disabled: boolean }).disabled).toBe(true);

    act(() => {
      (confirmButton.props as { onPress: () => void }).onPress();
    });
    expect(onConfirm).not.toHaveBeenCalled();
  });

  it('still calls onConfirm normally when confirmDisabled is false (default)', () => {
    const onConfirm = jest.fn();
    const renderer = render(
      <ConfirmationDialog visible title="t" message="m" onConfirm={onConfirm} onCancel={jest.fn()} />,
    );
    const buttons = renderer.root.findAllByType(TouchableOpacity as never);
    const confirmButton = buttons.find(
      (b) => (b.props as { accessibilityLabel?: string }).accessibilityLabel === 'Confirm',
    )!;
    act(() => {
      (confirmButton.props as { onPress: () => void }).onPress();
    });
    expect(onConfirm).toHaveBeenCalledTimes(1);
  });
});
