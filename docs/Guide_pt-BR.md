# Do `Button1Click` ao SafeThread4D

### Um guia pelos conceitos de threading em Delphi, do problema real ao mecanismo que resolve

---

Se você já escreveu algo em Delphi que fez o botão ficar branco, o cursor virar ampulheta e o usuário continuar clicando achando que o aplicativo travou, este texto é para você.

A boa notícia é que existe solução. A notícia menos confortável é que a solução envolve aprender alguns conceitos que, à primeira vista, parecem teoria distante da prática: *threads, sincronização, memory ordering, operações atômicas, events, heartbeat, cancelamento cooperativo*. A proposta aqui é seguir o caminho natural: começar pela dor real, mostrar como ela aparece no código, e só então introduzir o conceito que resolve aquele problema.

Ao final, a ideia é que você entenda não apenas **como** usar threads em Delphi, mas **por que** cada parte existe. Como culminação prática, você verá o **SafeThread4D**, um mecanismo que consolida essas decisões em uma API pequena na superfície, mas densa por baixo.

---

## Parte 1 — Por que threads existem?

Imagine uma tela com dois botões: **Download** e **Upload**.
O usuário clica em **Download**. A operação começa.
Antes de terminar, ele tenta clicar em **Upload**. Não consegue.
Tenta mover a janela, clicar de novo, interagir com a tela e a interface já não responde como deveria.

**Isso não acontece porque o código do botão é "extenso".**
Acontece porque a *main thread* ficou ocupada por tempo demais.

Em Delphi, a *main thread* — também chamada de *thread principal* ou *UI thread* — é quem desenha a interface, recebe os cliques, processa eventos, atualiza controles e executa o código dos seus controles visuais.

Se uma operação bloqueante roda nela, a interface inteira fica esperando.

E aqui existe um detalhe importante: **nem sempre você percebe de antemão que aquela operação vai demorar**.
Às vezes o método parece pequeno. Às vezes o arquivo a ser baixado é pequeno. Às vezes a sua conexão parece rápida. Às vezes a renderização parece simples.
Mas o atraso pode estar em outro lugar: o servidor pode demorar para responder, a rede pode estar com latência alta, o banco de dados pode estar lento ou alguma dependência externa pode simplesmente não devolver o controle rapidamente.

Considere este exemplo aparentemente inocente:

```delphi
procedure TForm1.btDownloadClick(Sender: TObject);
var
  LHttp: THTTPClient;
  LStream: TMemoryStream;
begin
  LHttp := THTTPClient.Create;
  LStream := TMemoryStream.Create;
  try
    LHttp.Get('https://example.com/imagem.jpg', LStream);
    Image1.Bitmap.LoadFromStream(LStream);
  finally
    LStream.Free;
    LHttp.Free;
  end;
end;
```

O ponto central é este:

> **não importa se o método tem 3 linhas ou 300.**
> Se ele prende a main thread por tempo demais, a interface deixa de responder como deveria.

A ideia por trás de **threading** é justamente mover esse tipo de operação, potencialmente demorada, para outra linha de execução.

> **Thread** é uma linha de execução independente dentro do mesmo processo.
> Enquanto a main thread cuida da interface, outra thread pode baixar arquivos, ler o banco de dados, processar dados, serializar conteúdo ou executar qualquer operação bloqueante sem paralisar a UI.

A intuição é simples. Os problemas começam quando tentamos fazer isso de forma incorreta.

---

## Parte 2 — Criando sua primeira thread

Em Delphi, a forma mais direta de criar uma thread é usando `TThread.CreateAnonymousThread`:

```delphi
procedure TForm1.btDownloadClick(Sender: TObject);
begin
  TThread.CreateAnonymousThread(
    procedure
    var
      LHttp: THTTPClient;
      LStream: TMemoryStream;
    begin
      LHttp := THTTPClient.Create;
      LStream := TMemoryStream.Create;
      try
        LHttp.Get('https://example.com/imagem.jpg', LStream);
        Image1.Bitmap.LoadFromStream(LStream); // ← o problema está aqui
      finally
        LStream.Free;
        LHttp.Free;
      end;
    end
  ).Start;
end;
```

### Nota — O que é esse `procedure` dentro do `CreateAnonymousThread`?

Se você nunca viu essa construção antes, pode parecer estranho ter uma `procedure` declarada **dentro** da chamada de um método. Isso tem um nome: **método anônimo** (ou *closure*).

Um método anônimo é um pedaço de código que pode ser **passado como parâmetro**, como se fosse um valor comum. Ele não tem nome, por isso "anônimo".

O que o torna especial é que ele **lembra das variáveis do escopo onde foi criado**. Ou seja, variáveis declaradas no método que contém a closure continuam acessíveis **de dentro** dela, mesmo quando a closure for executada depois, em outro contexto — inclusive em outra thread.

No exemplo acima, a `procedure` passada para `CreateAnonymousThread` é um método anônimo. Quando `Start` é chamado, a thread executa aquele bloco de código em segundo plano. Essa ideia vai aparecer várias vezes ao longo deste guia, e é o mecanismo pelo qual a API do SafeThread4D recebe seus callbacks de lifecycle (`OnExecute`, `OnSuccess`, `OnError`, etc.).

---

Você executa. A tela **não congela** mais durante o download. Parece que funcionou.

Mas o programa pode passar a se comportar de forma estranha: imagem corrompida, crashes intermitentes, falhas que não aparecem sempre — às vezes só na máquina do cliente.

O motivo é importante:

> **Componentes visuais pertencem à main thread.**
> Em Delphi, você não deve tocar em `TLabel`, `TButton`, `TImage`, `TGrid`, `TMemo`, `TListView` ou qualquer outro controle visual a partir de uma thread de trabalho.

A regra de ouro é esta:

> **A UI só pode ser manipulada pela main thread.**

Isso resolve um dos problemas. Mas, quando começamos a colocar trabalho em paralelo, aparece outro tipo de cuidado.

---

## Parte 3 — Quando a thread resolve um problema, aparece outro

Depois que você move uma operação para uma worker thread, a interface deixa de travar. Ótimo.

Mas agora existe uma nova realidade: **duas linhas de execução passam a coexistir** dentro do mesmo processo.

- a **main thread** continua responsável pela interface;
- a **worker thread** passa a executar o trabalho demorado.

No começo, isso parece simples. Mas logo aparece um novo tipo de pergunta:

> **como duas threads diferentes compartilham ou publicam estado corretamente?**

Mesmo antes de entrar no caso clássico de race condition, já existe uma preocupação prática: uma thread produz informação, e a outra precisa refletir essa informação na UI.

Por exemplo: uma worker thread pode estar baixando uma série de imagens, e a interface pode querer mostrar quantas já terminaram. A thread de trabalho avança; a interface precisa acompanhar.

É nesse ponto que conceitos como **publicação de estado**, **sincronização com a UI** e **coordenação entre threads** começam a importar.

Mas o race condition clássico fica mais fácil de ver em um exemplo ainda mais simples: várias threads alterando o mesmo contador.

---

## Parte 4 — Race conditions: quando várias threads alteram o mesmo estado

Uma **race condition** acontece quando o resultado correto depende da ordem exata em que várias threads estão em execução — e essa ordem é imprevisível.

Um exemplo clássico é um contador compartilhado.

### Exemplo incorreto: várias threads incrementando um contador comum

```delphi
var
  GContador: Integer;

procedure TForm1.Button1Click(Sender: TObject);
var
  I: Integer;
begin
  GContador := 0;

  for I := 1 to 10 do
    TThread.CreateAnonymousThread(
      procedure
      var
        J: Integer;
      begin
        for J := 1 to 100000 do
          Inc(GContador);
      end
    ).Start;

  Sleep(2000); // apenas ilustrativo — veja a observação ao final desta seção
  ShowMessage('Contador = ' + IntToStr(GContador));
end;
```

Observe que o loop `for` dispara 10 threads. À primeira vista, parece que o resultado deveria ser sempre **1.000.000**.

Mas não é. Dependendo da execução, você pode obter números menores.
O motivo é que `Inc(GContador)` **não é uma operação atômica**. Por baixo, ela envolve leitura, soma e escrita. Se várias threads fizerem isso ao mesmo tempo, uma atualização pode sobrescrever a outra.

Vale destacar outro ponto: uma thread criada quando `I = 9` pode muito bem começar a executar antes de qualquer uma das anteriores. A ordem real de execução é decidida pelo sistema operacional, não pela ordem de criação. Nesse cenário específico, isso é imprevisível.

É exatamente isso que caracteriza o race condition:

> **duas ou mais threads alteram o mesmo estado, mas sem sincronização adequada.**

### Exemplo correto: o mesmo cenário, mas com operação atômica

Agora veja o mesmo exemplo, mas tratando o contador corretamente. O `GContador` é a mesma variável global do exemplo anterior; a única diferença está em como ele é incrementado:

```delphi
uses
  System.SyncObjs;

procedure TForm1.Button2Click(Sender: TObject);
var
  I: Integer;
begin
  GContador := 0;

  for I := 1 to 10 do
    TThread.CreateAnonymousThread(
      procedure
      var
        J: Integer;
      begin
        for J := 1 to 100000 do
          TInterlocked.Increment(GContador);
      end
    ).Start;

  Sleep(2000); // apenas ilustrativo — veja a observação ao final desta seção
  ShowMessage('Contador = ' + IntToStr(GContador));
end;
```

Aqui a diferença está em uma única linha:

```delphi
TInterlocked.Increment(GContador);
```

Agora o incremento passa a ser **atômico** do ponto de vista concorrente.
As threads ainda executam em paralelo, mas a atualização do contador deixa de ser vulnerável à interlevação incorreta de leitura, soma e escrita.

> **Nota:** `TInterlocked` será apresentado formalmente na Parte 7. Por ora, basta saber que é a forma correta de incrementar um inteiro compartilhado entre threads.

### O que esse contraste ensina

Os dois botões fazem praticamente a mesma coisa:

- criam várias threads;
- cada thread executa muitos incrementos;
- no final, o programa exibe o valor do contador.

Mas existe uma diferença essencial:

- no primeiro botão, o contador é alterado de forma ingênua;
- no segundo, ele é alterado com uma operação atômica.

Esse contraste mostra um ponto central:

> **o problema não é simplesmente "usar várias threads".**
> O problema é **usar várias threads sobre o mesmo estado sem coordenação correta**.

### Onde esse padrão aparece na prática

Embora este exemplo use um contador simples, a ideia por trás dele aparece com frequência em software real.

Esse tipo de estado compartilhado é comum quando queremos acompanhar, por exemplo:

- quantos downloads já terminaram;
- quantos registros já foram processados;
- quantas tarefas ainda estão em execução;
- quantos itens deram erro;
- quantos workers continuam ativos.

Em muitos casos, esses números acabam sendo mostrados na interface: labels, barras de progresso, grades, listas de status, indicadores visuais e outros elementos da main thread.

É justamente aí que o cuidado precisa aumentar:

- o estado compartilhado entre threads precisa ser atualizado corretamente;
- e a interface precisa ser atualizada no contexto correto, isto é, pela main thread.

Ou seja: o contador do exemplo é pequeno, mas o padrão que ele representa é extremamente comum em cenários reais.

### Até onde vai este exemplo

O exemplo do contador foi escolhido porque deixa o erro visível com facilidade. Ele é uma boa porta de entrada para entender race condition e a utilidade de operações atômicas como `TInterlocked`.

Mas o problema de concorrência não se limita a variáveis numéricas. Estado compartilhado mais complexo — como mensagens, listas, objetos, coleções ou combinações de valores usadas pela interface — pode exigir outras formas de coordenação, como ownership bem definido, publicação explícita, `TMonitor`, `TCriticalSection` ou outras estratégias equivalentes.

Esses casos existem e são importantes, mas ampliariam bastante o escopo deste texto. Aqui, a ideia é construir a intuição correta sem transformar o guia em um tratado completo de sincronização.

Esse aprofundamento pode ser tratado em uma continuação futura.

### Observação importante

Nestes dois exemplos, o `Sleep(2000)` foi mantido apenas para simplificar a demonstração.

Como ele está no `Button1Click` / `Button2Click`, ele roda na **main thread** e, por isso, congela a interface temporariamente.

Em código real, esperar o término de threads com `Sleep` não é a abordagem correta.
Mais adiante veremos mecanismos apropriados para coordenação de término, como `TEvent`, e, no caso do SafeThread4D, o papel do `FCompletedEvent` e do `CancelAndWait`.

---

## Parte 5 — O modelo de memória dos processadores modernos

A intuição natural é pensar: "linha 1, depois linha 2, depois linha 3".

Na prática, processadores modernos fazem duas coisas para ganhar performance:

1. **Reordenação de instruções**: se uma operação não depende da anterior, a CPU pode executá-la em outra ordem.
2. **Caches por núcleo**: uma escrita pode ficar temporariamente visível apenas para um núcleo, enquanto outro ainda enxerga o valor antigo.

Do ponto de vista da sua própria thread, tudo parece coerente. Mas, para outra thread rodando em outro núcleo, a ordem e a visibilidade dos dados podem ser diferentes.

Esse é o problema de **memory ordering**.

A intuição útil para guardar é:

> **Cada thread tem sua própria visão momentânea da memória compartilhada.**
> Essa memória só passa a se comportar como verdadeiramente compartilhada quando existe sincronização correta.

É por isso que um simples `Contador := Contador + 1` não é seguro entre threads. E é por isso que até um `while not Terminou do Sleep(10)` pode ser inadequado se essa flag não estiver sendo publicada corretamente.

Agora que os problemas foram apresentados, vamos às ferramentas.

---

## Parte 6 — `Synchronize` e `Queue`: como falar com a main thread

Voltando ao problema da UI: se a thread de trabalho não pode tocar a interface diretamente, como ela pede que a interface seja atualizada?

Delphi oferece dois mecanismos centrais para isso: `Synchronize` e `Queue`.

### `TThread.Synchronize`

```delphi
TThread.Synchronize(nil,
  procedure
  begin
    Image1.Bitmap.LoadFromStream(LStream);
    Label1.Text := 'Pronto';
  end
);
```

A thread de trabalho pede para a main thread executar aquele código **e espera** até que isso aconteça.

É uma chamada **síncrona**.

### `TThread.Queue`

```delphi
TThread.Queue(nil,
  procedure
  begin
    Label1.Text := 'Progresso: 45%';
  end
);
```

Aqui a thread de trabalho apenas **enfileira** um pedido para a main thread e segue adiante. A execução visual acontece depois, quando a main thread processar a fila.

É uma chamada **assíncrona**.

### Intuição prática

- Use **`Synchronize`** quando a lógica seguinte depende da UI já ter sido atualizada.
- Use **`Queue`** quando você só quer notificar a UI e seguir o trabalho.

Regra curta:

> **`Synchronize` espera. `Queue` publica.**

### Importante — armadilhas comuns

`Synchronize` é feito para ser chamado **a partir de uma worker thread**, pedindo que a main thread execute código de UI.

Dois padrões a evitar:

- **Chamar `Synchronize` a partir da própria main thread.** A main thread não pode esperar por si mesma. Dependendo do contexto, isso pode causar deadlock ou comportamento imprevisível.
- **Aninhar `Synchronize` dentro de outro `Synchronize`.** A chamada externa já está rodando na main thread; a chamada interna estaria pedindo que a main thread espere por si mesma. Mesmo tipo de armadilha.

O modelo mental é simples: `Synchronize` é uma ponte **da worker para a UI**. Ele não foi pensado para ser chamado quando você já está do lado da UI. O `CancelAndWait` do SafeThread4D, por exemplo, rejeita explicitamente ser chamado a partir da main thread justamente por essa razão.

Isso resolve a comunicação com a interface. Mas ainda falta resolver o compartilhamento seguro de estado entre threads.

---

## Parte 7 — Operações atômicas

Voltando ao contador da Parte 4: a forma correta de incrementá-lo entre threads é usar uma operação atômica.

Em Delphi, isso significa usar `TInterlocked`:

```delphi
uses
  System.SyncObjs;

var
  GContador: Integer;

begin
  GContador := 0;
  TInterlocked.Increment(GContador);
end;
```

Agora o incremento passa a ser indivisível do ponto de vista concorrente, e o valor é publicado corretamente para as outras threads.

`TInterlocked` oferece um conjunto essencial de ferramentas:

- `Increment`
- `Decrement`
- `Add`
- `Exchange`
- `CompareExchange`

> **Sempre que uma variável for compartilhada entre threads, parta do princípio de que ela precisa de acesso atômico.**

No SafeThread4D isso aparece o tempo todo:

- `FRunningInt`
- `FExecutionActiveInt`
- `FCancelRequested`
- `FThreadHadErrorInt`

Todos parecem inteiros simples, mas são manipulados via `TInterlocked`. Isso não é exagero. É a forma correta de publicar estado concorrente.

---

## Parte 8 — `TEvent`: esperar sem polling, sem desperdiçar CPU

Suponha agora que uma thread precise esperar outra terminar.

A solução errada é esta:

```delphi
while not Terminou do
  Sleep(10);
```

Isso é ruim por três razões:

1. a flag pode não estar sendo publicada corretamente;
2. você faz polling desnecessário;
3. se isso acontecer na main thread, a UI congela novamente.

A ferramenta correta é `TEvent`.

```delphi
uses
  System.SyncObjs;

var
  FEventoPronto: TEvent;

begin
  FEventoPronto := TEvent.Create(nil, True, False, '');
end;
```

Uma thread faz:

```delphi
FEventoPronto.SetEvent;
```

Outra faz:

```delphi
FEventoPronto.WaitFor(INFINITE);
```

Enquanto o evento não for sinalizado, quem espera fica realmente bloqueado, sem polling e sem consumo desnecessário de CPU.

> **`TEvent` é o mecanismo correto para coordenação de espera entre threads.**

No SafeThread4D isso aparece no `FCompletedEvent`, que é a base do `CancelAndWait`.

---

## Parte 9 — Cancelamento cooperativo

Agora imagine este cenário: o usuário iniciou o download e depois clicou em "Cancelar".

A pior ideia seria "matar" a thread abruptamente. Uma thread pode estar:

- no meio de uma escrita;
- segurando um recurso;
- no meio de uma alteração estrutural;
- dentro de um `finally` que ainda precisa rodar.

Por isso, o modelo moderno é **cancelamento cooperativo**.

A ideia é simples:

- a thread principal **sinaliza** que quer cancelar;
- a thread de trabalho, em pontos estratégicos, **verifica** essa sinalização;
- se o cancelamento foi pedido, ela sai de forma limpa.

Exemplo conceitual:

```delphi
var
  FCancelado: Integer;

procedure TForm1.btCancelarClick(Sender: TObject);
begin
  TInterlocked.Exchange(FCancelado, 1);
end;
```

Na thread:

```delphi
if TInterlocked.CompareExchange(FCancelado, 0, 0) = 1 then
  Exit;
```

Se o trecho acima parece estranho, eis o que ele faz: `CompareExchange(x, 0, 0)` é o idiom padrão em Delphi para **ler um `Integer` de forma atômica**. Ele compara `x` com `0`, troca por `0` se forem iguais (na prática, um no-op) e retorna o valor anterior. O efeito líquido é "ler o valor atual de `x` com todas as garantias de memory ordering". Em versões do Delphi onde está disponível, `TInterlocked.Read` faz a mesma coisa de forma mais direta.

No SafeThread4D, isso vira algo mais limpo:

```delphi
TSafeThread4D.CheckCancel(Params, Context);
```

Se o cancelamento foi pedido, o mecanismo levanta uma exceção específica (`EOperationCancelled`) e a execução sai passando por todos os `finally` necessários.

> **Cancelamento cooperativo não arranca a thread à força. Ele deixa a thread terminar com limpeza.**

---

## Parte 10 — ANR no Android e a ideia de heartbeat

Se você desenvolve também para Android, existe uma preocupação adicional: o sistema operacional vigia a responsividade da UI.

Existe um mecanismo do próprio Android chamado **watchdog** — literalmente "cão de guarda". É um componente do sistema operacional que fica observando a main thread do aplicativo. Se ela passar tempo demais sem demonstrar atividade suficiente, o watchdog conclui que o aplicativo travou e apresenta a conhecida janela de ANR (*Application Not Responding*), com opção de fechar o app.

Mesmo quando o trabalho pesado está fora da main thread, ainda existem cenários em que a UI pode ficar "silenciosa" por tempo demais para o watchdog, especialmente em operações longas com sincronizações pontuais.

Uma estratégia prática para isso é o **heartbeat**:

> uma thread auxiliar, em intervalos regulares, publica um pequeno "pulso" na main thread para mostrar que a interface continua viva.

Exemplo conceitual:

```delphi
// Pseudocódigo conceitual
while FStopEvent.WaitFor(500) <> wrSignaled do
begin
  TThread.Queue(nil,
    procedure
    begin
      // Pequeno pulso na UI
    end);
end;

// Em outro ponto:
FStopEvent.SetEvent;
```

A ideia parece simples. Implementar corretamente, não.

As dificuldades reais são:

- parar o heartbeat na hora certa;
- não deixar pings residuais depois que a tarefa termina;
- evitar callbacks para UI morta;
- acertar a ordem de desligamento.

É exatamente por isso que o SafeThread4D trata heartbeat como parte do mecanismo, e não como detalhe improvisado em cada projeto.

---

### Nota — Referências fortes e fracas em Delphi

Antes de entrar na Parte 11, vale parar um momento para entender um conceito que aparece no próximo exemplo: o par **referência forte / referência fraca**.

Em Delphi, quando você trabalha com **interfaces** (como `ISafeThread4DParams`), o objeto por baixo usa **contagem de referências**. Cada vez que alguém guarda a interface em uma variável, um contador interno sobe. Quando a variável sai de escopo ou é zerada, o contador desce. Quando ele chega a zero, o objeto é liberado automaticamente.

Uma **referência forte** é a variável normal do dia a dia:

```delphi
var
  LParams: ISafeThread4DParams; // referência forte
begin
  LParams := TSafeThread4DParams.New; // contador sobe para 1
end; // LParams sai de escopo, contador volta para 0, objeto é liberado
```

Uma **referência fraca** é uma cópia do endereço do objeto que **não** participa da contagem. Em Delphi, o usual é converter a interface para `Pointer`, o que não chama `AddRef`:

```delphi
var
  LWeakRef: Pointer;
begin
  LWeakRef := Pointer(LParams); // não incrementa o contador
end;
```

Por que isso importa? Porque existe uma armadilha chamada **retain cycle**: se um objeto guarda uma referência forte a um método anônimo, e esse método anônimo, por sua vez, captura esse mesmo objeto de forma forte, os dois acabam mantendo um ao outro vivo para sempre. Nenhum é liberado, mesmo quando ninguém mais precisa deles.

O padrão **weak + strong** resolve isso:

- uma variável externa ao closure mantém a referência **forte** (e controla o tempo de vida);
- dentro do closure, captura-se apenas uma referência **fraca** (um `Pointer`), que é reconvertida em interface tipada quando necessário.

O SafeThread4D expõe esse padrão explicitamente através de `StartThreadWithWeakRef`, justamente para que callbacks de `OnExecute` possam consultar os próprios `Params` (por exemplo, para chamar `CheckCancel`) sem criar retain cycle. Esse é o padrão que aparece no exemplo da Parte 11.

---

## Parte 11 — SafeThread4D: os conceitos em um pacote coeso

Voltemos ao download da Parte 1, agora escrito com SafeThread4D de forma fiel ao desenho atual.

O exemplo abaixo assume que a form possui dois campos privados: `FDownloadedStream: TMemoryStream` (para entregar o conteúdo baixado da worker para a UI) e `FParams: ISafeThread4DParams` (a referência forte usada para cancelamento e observação).

```delphi
uses
  System.Net.HttpClient,
  System.Classes,
  System.SysUtils,
  SafeThread4D;

procedure TForm1.btDownloadClick(Sender: TObject);
var
  LParams: ISafeThread4DParams;
  LWeakRef: Pointer;
begin
  LParams := TSafeThread4DParams.New
    .SetThreadName('DownloadImagem')
    .SetOnExecute(
      procedure(AContext: TThreadContext)
      var
        LHttp: THTTPClient;
        LStream: TMemoryStream;
        LP: ISafeThread4DParams;
      begin
        LP := ISafeThread4DParams(IInterface(LWeakRef));
        if LP = nil then
          raise Exception.Create('Internal error: WeakRef not initialized.');

        LHttp := THTTPClient.Create;
        LStream := TMemoryStream.Create;
        try
          TSafeThread4D.CheckCancel(LP, AContext);

          LHttp.Get('https://example.com/imagem-gigante.jpg', LStream);

          TSafeThread4D.CheckCancel(LP, AContext);

          LStream.Position := 0;

          // FDownloadedStream não é um controle visual, então atribuir a
          // posse do stream aqui não viola a regra de UI thread.
          // Ainda assim, ele continua sendo estado compartilhado e deve ser
          // tratado sob um contrato claro de ownership entre worker e UI.
          FDownloadedStream := LStream;
          LStream := nil; // transfer ownership
        finally
          LStream.Free;
          LHttp.Free;
        end;
      end
    )
    .SetOnSuccess(
      procedure(AContext: TThreadContext)
      begin
        if Assigned(FDownloadedStream) then
        begin
          FDownloadedStream.Position := 0;
          Image1.Bitmap.LoadFromStream(FDownloadedStream);
          FreeAndNil(FDownloadedStream);
        end;
        Label1.Text := 'Download concluído';
      end
    )
    .SetOnError(
      procedure(const AErrorMessage: string; const AContext: TThreadContext)
      begin
        FreeAndNil(FDownloadedStream);
        Label1.Text := 'Erro: ' + AErrorMessage;
      end
    )
    .SetOnCancel(
      procedure(AContext: TThreadContext)
      begin
        FreeAndNil(FDownloadedStream);
        Label1.Text := 'Cancelado pelo usuário';
      end
    )
    .SetHeartbeatIntervalMs(500)
    .SetOnHeartbeat(
      procedure
      begin
        // Pequeno pulso de UI — útil em cenários móveis longos
      end
    );

  TSafeThread4D.StartThreadWithWeakRef(LParams, LWeakRef, FParams);
end;

procedure TForm1.btCancelarClick(Sender: TObject);
begin
  if Assigned(FParams) then
    TSafeThread4D.Cancel(FParams);
end;
```

### O que cada peça resolve

| Peça                                        | O que resolve                                                                      |
| ------------------------------------------- | ---------------------------------------------------------------------------------- |
| `SetOnExecute`                              | Coloca o trabalho potencialmente demorado fora da main thread.                     |
| `SetOnSuccess`                              | Garante que a atualização da UI aconteça na main thread.                           |
| `SetOnError`                                | Centraliza a falha em contexto seguro de UI.                                       |
| `SetOnCancel`                               | Dá um caminho limpo para cancelamento observado.                                   |
| `CheckCancel`                               | Implementa cancelamento cooperativo.                                               |
| `SetHeartbeatIntervalMs` + `SetOnHeartbeat` | Oferece pulsos opcionais de UI para cenários móveis longos.                        |
| `TInterlocked` interno                      | Garante publicação segura do estado compartilhado.                                 |
| `FCompletedEvent` interno                   | Permite espera segura via `CancelAndWait`, sem depender da vida útil do `TThread`. |
| `StartThreadWithWeakRef`                    | Evita retain cycle quando o callback precisa usar os próprios `Params`.            |

### Observações importantes sobre este exemplo

1. **Se o seu `OnExecute` não precisa consultar `Params`**, você pode usar `StartThread(...)` normalmente e evitar o padrão weak+strong.
2. **Se o callback precisa chamar `CheckCancel`, `CheckTimeout` ou `ReportProgress`**, o padrão `StartThreadWithWeakRef` é o caminho mais seguro para não capturar os próprios `Params` fortemente.
3. Em um aplicativo real, a referência forte (`FParams`, neste exemplo) deve ser liberada quando não for mais necessária — tipicamente em `OnTerminate` ou `OnTerminateEvent`.
4. O heartbeat **mitiga cenários de ANR**, mas não deve ser vendido como "garantia mágica". Ele existe para manter a UI respirando em cenários reais e longos, especialmente em mobile.
5. `OnCancel` não significa que toda a limpeza estrutural já terminou. Significa que o cancelamento foi observado e o callback de UI correspondente foi disparado. A publicação final de término ainda passa pelo restante do lifecycle e pelo proxy de terminação.
6. **`Cancel` apenas solicita o cancelamento; ele não espera o worker terminar.** Isso é proposital — o handler `btCancelarClick` roda na main thread, e a main thread nunca deve ficar bloqueada esperando um worker. Se você realmente precisa esperar até que o worker tenha terminado (por exemplo, em uma sequência de shutdown customizada executada a partir de uma thread em segundo plano), use `TSafeThread4D.CancelAndWait(Params)`. Como discutido na Parte 8, essa espera é construída sobre um `TEvent` interno, e a API rejeita explicitamente ser chamada a partir da main thread.

O SafeThread4D nasceu da observação de que, em cada novo projeto que exigia threading robusto — progresso, cancelamento, timeout, heartbeat, sincronização correta, encerramento ordenado — o mesmo conjunto de padrões era reescrito com pequenas variações e, quase sempre, com bugs sutis. Depois de enfrentar esses problemas repetidas vezes, a solução foi implementar o conjunto completo uma única vez, com testes, revisão e disciplina, e então disponibilizá-lo para reuso.

O resultado é um mecanismo de superfície pequena (poucos métodos públicos), mas denso em decisões corretas por baixo. Com cerca de 30 linhas de configuração fluente, o desenvolvedor obtém:

- execução em thread separada com lifecycle previsível;
- progresso *throttled*, sem saturar a fila da main thread;
- cancelamento cooperativo via exceção limpa;
- timeout cooperativo com a mesma mecânica;
- heartbeat com shutdown ordenado, sem pings residuais;
- espera segura via `CancelAndWait`, usando `TEvent` interno;
- nomeação de thread para depuração;
- flags atômicas em todo estado compartilhado;
- e vários detalhes adicionais que o usuário não precisa gerenciar manualmente.

---

## Leituras recomendadas

Para o leitor que quer se aprofundar no universo das threads em Delphi, três trabalhos merecem destaque na literatura da área:

- **Primož Gabrijelčič** — [*Delphi High Performance* (2ª edição)](https://www.amazon.com/dp/1805125877)
- **Dalija Prasnikar** — [*Delphi Thread Safety Patterns*](https://www.amazon.com/dp/B0BJ8BD22J)
- **Cesar Romero Silva** — [*Delphi Multithreading: Threads, Concorrência, Paralelismo e Assincronismo*](https://www.amazon.com/dp/6501752515)

---

## Epílogo — Próximos passos

Se você chegou até aqui, já tem uma base conceitual sólida em threading. E isso já tem grande valor: você sabe **por que** cada peça existe.

Próximos passos naturais:

1. **Clone o SafeThread4D** e execute os exemplos.
2. **Consulte o README** do projeto, com casos de uso mais elaborados.
3. **Leia o `Architecture.md`** se quiser entender o mecanismo por dentro.
4. **Leia o código-fonte** com calma. O importante não é decorar, mas reconhecer os padrões.

E se, em algum momento, você encontrar o seu próprio `Button1Click` com uma thread dentro, `TInterlocked` espalhado pelo código, um `TEvent` perdido em algum lugar e uma flag de cancelamento sobre a qual você não tem certeza se está sendo publicada corretamente, talvez essa seja exatamente a hora de parar de reconstruir o mecanismo do zero em cada projeto.

---

*Este texto é um guia conceitual introdutório. Para uso prático e detalhes do mecanismo, consulte o [README.md](../README.md) , o documento de arquitetura e os exemplos do projeto.*